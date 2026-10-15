// lib/sources/soulseek_desktop/soulseek_transfer_manager.dart
//
// Очередь и управление загрузками Soulseek на Windows — порт
// SoulseekTransferManager.kt.
//
// Разделение ответственности то же, что на Android:
//  - мост (.NET) выполняет саму передачу: `.part`, resume по offset, проверка
//    файла, прогресс с throttle 250 мс;
//  - менеджер: лимит параллельных загрузок, retry с экспоненциальным
//    backoff, pause / resume / cancel, объединение запросов одного cacheKey,
//    персист состояний, события в контракте SoulseekEvent.
// Плюс публикация `.part` в кэш (на Android её делает мост).

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../soulseek_models.dart';
import 'soulseek_desktop_cache.dart';
import 'soulseek_desktop_store.dart';
import 'soulseek_native_bridge.dart';

class SoulseekTransferManager {
  SoulseekTransferManager({
    required SoulseekBridgeTransport bridge,
    required SoulseekDesktopStore store,
    required this.cache,
    int maxConcurrentDownloads = defaultMaxConcurrent,
    Duration Function(int attempt)? retryDelay,
  })  : _bridge = bridge,
        _store = store,
        _slots = _Slots(_clampConcurrency(maxConcurrentDownloads)),
        _retryDelay = retryDelay ?? defaultRetryDelay;

  static const int defaultMaxConcurrent = 3;
  static const int _maxConcurrentCap = 8;

  /// Максимальное число попыток для retryable-ошибок.
  static const int maxRetryAttempts = 3;

  static const Duration _checkpointThrottle = Duration(seconds: 1);

  /// Экспоненциальный backoff: 2 с × 2^attempt, предел 30 с, jitter до 10%.
  static Duration defaultRetryDelay(int attempt) {
    final exp = 2000 * (1 << math.min(attempt, 4));
    final capped = math.min(exp, 30000);
    final jitter = math.Random().nextInt(capped ~/ 10 + 1);
    return Duration(milliseconds: capped - jitter);
  }

  final SoulseekBridgeTransport _bridge;
  final SoulseekDesktopStore _store;
  final SoulseekDesktopCache cache;
  final _Slots _slots;
  final Duration Function(int attempt) _retryDelay;

  final Map<String, _Transfer> _transfers = {};
  final Map<String, String> _cacheKeyToDownloadId = {};

  final StreamController<SoulseekTransferInfo> _events =
      StreamController<SoulseekTransferInfo>.broadcast();

  bool _shutdown = false;

  /// Изменения трансферов (прогресс, состояния, завершение).
  Stream<SoulseekTransferInfo> get events => _events.stream;

  set maxConcurrentDownloads(int value) =>
      _slots.max = _clampConcurrency(value);

  static int _clampConcurrency(int v) => v.clamp(1, _maxConcurrentCap);

  // ───────────────────────────────────────────────────────────────────
  //  Public API
  // ───────────────────────────────────────────────────────────────────

  /// Запускает загрузку (или присоединяется к идущей). Cache hit — сразу
  /// путь к готовому файлу.
  Future<SoulseekDownloadResult> startDownload({
    required String downloadId,
    required String peerUsername,
    required String remoteFilename,
    required int sizeBytes,
    required String cacheKey,
    required String fileExtension,
    String? title,
    String? artist,
    int? durationSeconds,
  }) async {
    if (_shutdown) {
      throw const SoulseekException(
          'SERVICE_SHUTDOWN', 'Transfer manager is shutting down');
    }

    // 1. Cache hit: файл уже полностью скачан.
    final entry = await cache.getCacheEntry(cacheKey);
    if (entry != null) {
      // Файл, докачанный без метаданных (prefetch), получает их сейчас.
      await cache.fillMissingMetadata(cacheKey,
          title: title, artist: artist, durationSeconds: durationSeconds);
      _emitInfo(SoulseekTransferInfo(
        downloadId: downloadId,
        state: SoulseekTransferState.completed,
        bytesReceived: entry.sizeBytes,
        totalBytes: sizeBytes,
        localPath: entry.localPath,
        title: title ?? entry.title,
        artist: artist ?? entry.artist,
        remoteFilename: remoteFilename,
      ));
      return SoulseekDownloadResult(
        downloadId: downloadId,
        result: entry.localPath,
        cacheHit: true,
      );
    }

    final partPath = cache.partPath(cacheKey);

    // 2. Dedupe: этот cacheKey уже загружается — тот же downloadId.
    final existingId = _cacheKeyToDownloadId[cacheKey];
    final existing = existingId == null ? null : _transfers[existingId];
    if (existing != null && !existing.state.isTerminal) {
      // Загрузка без метаданных (prefetch, restore) — дополняем ими.
      if ((existing.title?.isEmpty ?? true) &&
          title != null &&
          title.isNotEmpty) {
        existing
          ..title = title
          ..artist = artist
          ..durationSeconds = durationSeconds;
        await _persist(existing);
        _emit(existing);
      }
      // Прерванная (выход, ручное отключение) загрузка — продолжаем, иначе
      // стриминг ждал бы прироста `.part`, которого не будет.
      if (existing.state == SoulseekTransferState.paused) {
        await resumeDownload(existing.downloadId);
      }
      return SoulseekDownloadResult(
        downloadId: downloadId,
        result: existing.downloadId,
        cacheHit: false,
        partPath: partPath,
      );
    }

    // 3. Новая загрузка (или resume по `.part` — мост продолжит с offset).
    final t = _Transfer(
      downloadId: downloadId,
      cacheKey: cacheKey,
      peerUsername: peerUsername,
      remoteFilename: remoteFilename,
      sizeBytes: sizeBytes,
      fileExtension: fileExtension,
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      state: SoulseekTransferState.queued,
    );
    _transfers[downloadId] = t;
    _cacheKeyToDownloadId[cacheKey] = downloadId;
    // Отложенное удаление `.part` прошлой отменённой загрузки не должно
    // снести файл новой.
    cache.cancelPendingDelete(partPath);
    await _persist(t);
    _emit(t);
    unawaited(_process(t));

    return SoulseekDownloadResult(
      downloadId: downloadId,
      result: downloadId,
      cacheHit: false,
      partPath: partPath,
    );
  }

  /// Пауза: отмена передачи в мосте; `.part` остаётся для resume.
  Future<void> pauseDownload(String downloadId) async {
    final t = _require(downloadId);
    // Гонка с завершением: готовую загрузку не превращаем в PAUSED.
    if (t.state.isTerminal || t.state == SoulseekTransferState.paused) return;
    t.pauseRequested = true;
    await _cancelBridgeTransfer(t);
    t.state = SoulseekTransferState.paused;
    t.bytesPerSecond = 0;
    await _checkpointFromPart(t);
    await _persist(t);
    _emit(t);
    t.wake();
  }

  /// Resume: перезапуск загрузки с offset `.part`.
  Future<void> resumeDownload(String downloadId) async {
    final t = _require(downloadId);
    if (t.state.isTerminal) {
      throw SoulseekException(
          'TRANSFER_TERMINAL', 'Transfer is in terminal state ${t.state.name}');
    }
    // Уже идёт — второй retry-loop запустил бы вторую загрузку того же `.part`.
    if (t.state != SoulseekTransferState.paused) return;
    t.pauseRequested = false;
    t.cancelRequested = false;
    t.retrySignal = false;
    t.state = SoulseekTransferState.queued;
    cache.cancelPendingDelete(cache.partPath(t.cacheKey));
    await _persist(t);
    _emit(t);
    unawaited(_process(t));
  }

  /// Cancel: отмена и удаление `.part`.
  Future<void> cancelDownload(String downloadId) async {
    final t = _require(downloadId);
    if (t.state.isTerminal) return;
    t.cancelRequested = true;
    t.pauseRequested = false;
    await _cancelBridgeTransfer(t);
    t.state = SoulseekTransferState.cancelled;
    cache.deleteWhenIdle(cache.partPath(t.cacheKey));
    _emit(t, message: 'Download cancelled by user');
    await _persist(t);
    _cleanupMappings(t);
    t.wake();
  }

  List<SoulseekTransferInfo> getActiveTransfers() => _transfers.values
      .where((t) => !t.state.isTerminal)
      .map((t) => t.info())
      .toList();

  List<SoulseekTransferInfo> getAllTransfers() =>
      _transfers.values.map((t) => t.info()).toList();

  SoulseekTransferInfo? getTransfer(String downloadId) =>
      _transfers[downloadId]?.info();

  /// После перезапуска: незавершённые загрузки — PAUSED (есть `.part`) или
  /// FAILED. Ничего не запускается автоматически, как на Android.
  Future<void> restore() async {
    for (final row in await _store.unfinishedTransfers()) {
      final part = await cache.existingPart(row.cacheKey);
      final t = _Transfer(
        downloadId: row.downloadId,
        cacheKey: row.cacheKey,
        peerUsername: row.peerUsername,
        remoteFilename: row.remoteFilename,
        sizeBytes: row.sizeBytes,
        fileExtension: row.fileExtension ?? 'dat',
        title: row.title,
        artist: row.artist,
        durationSeconds: row.durationSeconds,
        state: part != null
            ? SoulseekTransferState.paused
            : SoulseekTransferState.failed,
      )
        ..bytesReceived = part == null ? 0 : await part.length()
        ..retryCount = row.retryCount;
      _transfers[t.downloadId] = t;
      if (!t.state.isTerminal) _cacheKeyToDownloadId[t.cacheKey] = t.downloadId;
      await _persist(t);
    }
  }

  /// Отключение от сервера: активные загрузки встают на паузу (resume после
  /// подключения), а не падают вместе с клиентом.
  Future<void> pauseAll() async {
    for (final t in _transfers.values.toList()) {
      if (t.state.isTerminal || t.state == SoulseekTransferState.paused) {
        continue;
      }
      await pauseDownload(t.downloadId);
    }
  }

  /// Выход из приложения: активные загрузки → PAUSED (resume после рестарта).
  Future<void> shutdown() async {
    _shutdown = true;
    for (final t in _transfers.values) {
      if (t.state.isTerminal || t.state == SoulseekTransferState.paused) {
        continue;
      }
      t.pauseRequested = true;
      t.state = SoulseekTransferState.paused;
      await _checkpointFromPart(t);
      await _persist(t);
      t.wake();
    }
  }

  // ───────────────────────────────────────────────────────────────────
  //  Retry-loop
  // ───────────────────────────────────────────────────────────────────

  Future<void> _process(_Transfer t) async {
    // Поколение цикла: после pause → resume старый цикл (ждущий слот или
    // backoff) должен выйти, а не запустить вторую загрузку.
    final run = ++t.run;
    bool stale() => run != t.run;
    var attempt = t.retryCount;
    while (!t.cancelRequested && !t.pauseRequested && !stale()) {
      t.state = SoulseekTransferState.queued;
      _emit(t);
      await _slots.acquire();
      final lease = _SlotLease(_slots);
      t.lease = lease;
      try {
        if (t.cancelRequested || t.pauseRequested || stale()) break;
        // Прошлая попытка в мосте могла ещё не закрыть `.part`.
        await t.previousAttemptDone();
        if (t.cancelRequested || t.pauseRequested || stale()) break;
        t.state = SoulseekTransferState.downloading;
        _emit(t);
        t.retrySignal = false;
        await _checkpointFromPart(t);
        try {
          final waiter = t.arm();
          t.beginAttempt();
          await _bridge.call('startDownload', jsonEncode({
            // Уникален для попытки: события и отмена старой попытки не
            // путаются с новой (повторный запуск после паузы / retry).
            'downloadId': t.bridgeId,
            'peerUsername': t.peerUsername,
            'remoteFilename': t.remoteFilename,
            'sizeBytes': t.sizeBytes,
            'cacheKey': t.cacheKey,
            'localDirectory': cache.cacheDir,
            'fileExtension': t.fileExtension,
            'partPath': cache.partPath(t.cacheKey),
          }));
          // Мост качает в фоне; ждём терминального состояния, паузы,
          // отмены или промежуточной retryable-неудачи.
          if (!t.isSettled) await waiter;
        } on SoulseekException catch (e) {
          t.endAttempt(t.attempt);
          await _handleFailure(t, e, attempt);
        } catch (e) {
          t.endAttempt(t.attempt);
          await _handleFailure(
              t, SoulseekException('INTERNAL_ERROR', '$e'), attempt);
        }
      } finally {
        if (identical(t.lease, lease)) t.lease = null;
        lease.release();
      }

      if (t.state.isTerminal ||
          t.pauseRequested ||
          t.cancelRequested ||
          stale()) {
        break;
      }

      attempt++;
      t.retryCount = attempt;
      if (attempt >= maxRetryAttempts) {
        t.state = SoulseekTransferState.failed;
        _emit(t,
            errorCode: 'RETRIES_EXHAUSTED',
            message: 'Retry attempts exhausted after $attempt tries');
        await _persist(t);
        _cleanupMappings(t);
        break;
      }
      final delay = _retryDelay(attempt);
      debugPrint('[Soulseek] retrying ${t.downloadId} in ${delay.inMilliseconds} ms '
          '(attempt $attempt)');
      await Future<void>.delayed(delay);
    }
  }

  /// `dl_x#3` → (`dl_x`, 3); id без номера попытки — (id, null).
  static (String, int?) _splitBridgeId(String id) {
    final hash = id.lastIndexOf('#');
    if (hash < 0) return (id, null);
    final attempt = int.tryParse(id.substring(hash + 1));
    return attempt == null ? (id, null) : (id.substring(0, hash), attempt);
  }

  Future<void> _handleFailure(
      _Transfer t, SoulseekException e, int attempt) async {
    debugPrint('[Soulseek] transfer ${t.downloadId} failed (attempt $attempt): '
        '${e.code} ${e.message}');
    if (t.cancelRequested) {
      t.state = SoulseekTransferState.cancelled;
      _emit(t);
      await _persist(t);
      _cleanupMappings(t);
      return;
    }
    if (e.retryable && attempt + 1 < maxRetryAttempts && !t.pauseRequested) {
      t.state = SoulseekTransferState.queued;
      t.bytesPerSecond = 0;
      _emit(t);
      await _persist(t);
      return;
    }
    t.state = SoulseekTransferState.failed;
    _emit(t, errorCode: e.code, retryable: e.retryable, message: e.message);
    await _persist(t);
    _cleanupMappings(t);
  }

  // ───────────────────────────────────────────────────────────────────
  //  События моста
  // ───────────────────────────────────────────────────────────────────

  /// Transfer-события моста (downloadId != null).
  Future<void> handleBridgeEvent(Map<String, dynamic> e) async {
    final rawId = e['downloadId'];
    if (rawId is! String) return;
    final (downloadId, attempt) = _splitBridgeId(rawId);
    final t = _transfers[downloadId];
    if (t == null) return;
    final type = e['eventType'];
    final terminal = type == 'downloadComplete' || type == 'downloadFailed';
    if (attempt != null) {
      if (terminal) t.endAttempt(attempt);
      // Событие прошлой попытки (отменённой паузой или retry) — устарело.
      if (attempt != t.attempt) return;
    }
    switch (type) {
      case 'transferProgress':
        if (t.state.isTerminal || t.publishing) return;
        t.bytesReceived = _int(e['bytesReceived'], t.bytesReceived);
        t.bytesPerSecond = _int(e['bytesPerSecond'], 0);
        final total = _int(e['totalBytes'], t.sizeBytes);
        if (total > 0) t.sizeBytes = total;
        final now = DateTime.now();
        if (now.difference(t.lastCheckpointAt) >= _checkpointThrottle) {
          t.lastCheckpointAt = now;
          await _persist(t);
        }
        _emit(t);

      case 'transferStateChanged':
        if (t.state.isTerminal ||
            t.publishing ||
            t.pauseRequested ||
            t.cancelRequested) {
          return;
        }
        final mapped = SoulseekTransferState.fromString(e['state'] as String?);
        if (!mapped.isTerminal) {
          // Очередь у пира слот не держит; пир начал отдавать — слот
          // снова наш, если свободен.
          if (mapped == SoulseekTransferState.queuedRemotely) {
            t.lease?.release();
          } else if (mapped == SoulseekTransferState.downloading) {
            t.lease?.tryReacquire();
          }
          t.state = mapped;
          t.bytesReceived = _int(e['bytesReceived'], t.bytesReceived);
          _emit(t);
        }

      case 'downloadComplete':
        await _publish(t, e);

      case 'downloadFailed':
        await _onBridgeFailure(t, e);
    }
  }

  Future<void> _publish(_Transfer t, Map<String, dynamic> e) async {
    if (t.state.isTerminal || t.publishing) return;
    final partPath = e['localPath'] as String? ?? cache.partPath(t.cacheKey);
    final total = _int(e['totalBytes'], t.sizeBytes);
    if (total > 0) t.sizeBytes = total;
    t.bytesReceived = _int(e['bytesReceived'], t.sizeBytes);
    t.bytesPerSecond = 0;
    t.publishing = true;
    try {
      final path = await cache.publish(
        cacheKey: t.cacheKey,
        extension: t.fileExtension,
        partPath: partPath,
        title: t.title,
        artist: t.artist,
        durationSeconds: t.durationSeconds,
      );
      t.localPath = path;
      t.state = SoulseekTransferState.completed;
      _emit(t);
    } on Object catch (err) {
      debugPrint('[Soulseek] publish failed for ${t.downloadId}: $err');
      t.state = SoulseekTransferState.failed;
      _emit(t, errorCode: 'PUBLISH_FAILED', message: '$err');
    } finally {
      t.publishing = false;
    }
    await _persist(t);
    _cleanupMappings(t);
    t.wake();
  }

  Future<void> _onBridgeFailure(_Transfer t, Map<String, dynamic> e) async {
    if (t.state.isTerminal || t.publishing) return;
    final errorCode = e['errorCode'] as String?;
    final retryable = e['retryable'] == true;
    final raw = SoulseekTransferState.fromString(e['state'] as String?);

    // Пауза: передачу отменил сам pauseDownload — остаётся PAUSED.
    if (t.pauseRequested) {
      t.state = SoulseekTransferState.paused;
      t.bytesPerSecond = 0;
      _emit(t);
      await _persist(t);
      t.wake();
      return;
    }

    // Отмена пользователя — терминальная (CANCELLED, не FAILED).
    if (t.cancelRequested || raw == SoulseekTransferState.cancelled) {
      t.state = SoulseekTransferState.cancelled;
      t.bytesPerSecond = 0;
      _emit(t);
      await _persist(t);
      _cleanupMappings(t);
      t.wake();
      return;
    }

    // Битый файл: мост его удаляет, но на Windows открытый читателем
    // `.part` не удалить — дочищаем, когда закроют, иначе resume снова
    // упрётся в тот же остаток.
    if (errorCode != null && errorCode.startsWith('VALIDATION_')) {
      cache.deleteWhenIdle(cache.partPath(t.cacheKey));
    }

    // Сетевая/временная неудача в рамках бюджета попыток — retry-loop
    // продолжит с backoff; для Dart это не окончательный failure.
    if (retryable && t.retryCount + 1 < maxRetryAttempts) {
      t.state = SoulseekTransferState.queued;
      t.bytesPerSecond = 0;
      t.retrySignal = true;
      _emit(t);
      await _persist(t);
      t.wake();
      return;
    }

    t.state = SoulseekTransferState.failed;
    _emit(t,
        errorCode: errorCode,
        retryable: retryable,
        message: _nonEmpty(e['message']) ?? _nonEmpty(e['exceptionMessage']));
    await _persist(t);
    _cleanupMappings(t);
    t.wake();
  }

  // ───────────────────────────────────────────────────────────────────
  //  Хелперы
  // ───────────────────────────────────────────────────────────────────

  _Transfer _require(String downloadId) {
    final t = _transfers[downloadId];
    if (t == null) {
      throw SoulseekException(
          'TRANSFER_NOT_FOUND', 'Transfer $downloadId not found');
    }
    return t;
  }

  Future<void> _cancelBridgeTransfer(_Transfer t) async {
    if (!t.attemptActive) return;
    try {
      await _bridge.call('cancelTransfer', jsonEncode(t.bridgeId));
    } catch (e) {
      debugPrint('[Soulseek] cancelTransfer failed: $e');
    }
  }

  Future<void> _checkpointFromPart(_Transfer t) async {
    try {
      t.bytesReceived = await File(cache.partPath(t.cacheKey)).length();
    } on FileSystemException {
      // `.part` ещё нет.
    }
  }

  Future<void> _persist(_Transfer t) async {
    try {
      await _store.upsertTransfer(SoulseekTransferRow(
        downloadId: t.downloadId,
        cacheKey: t.cacheKey,
        peerUsername: t.peerUsername,
        remoteFilename: t.remoteFilename,
        sizeBytes: t.sizeBytes,
        state: t.state.name.toUpperCase(),
        bytesReceived: t.bytesReceived,
        localPath: t.localPath,
        fileExtension: t.fileExtension,
        retryCount: t.retryCount,
        title: t.title,
        artist: t.artist,
        durationSeconds: t.durationSeconds,
      ));
    } catch (e) {
      debugPrint('[Soulseek] persist transfer failed: $e');
    }
  }

  void _cleanupMappings(_Transfer t) {
    if (_cacheKeyToDownloadId[t.cacheKey] == t.downloadId) {
      _cacheKeyToDownloadId.remove(t.cacheKey);
    }
  }

  void _emit(_Transfer t,
      {String? errorCode, bool retryable = false, String? message}) {
    _emitInfo(t.info(
        errorCode: errorCode, retryable: retryable, message: message));
  }

  void _emitInfo(SoulseekTransferInfo info) {
    if (!_events.isClosed) _events.add(info);
  }

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

  static String? _nonEmpty(Object? v) =>
      v is String && v.isNotEmpty ? v : null;
}

class _Transfer {
  _Transfer({
    required this.downloadId,
    required this.cacheKey,
    required this.peerUsername,
    required this.remoteFilename,
    required this.sizeBytes,
    required this.fileExtension,
    required this.state,
    this.title,
    this.artist,
    this.durationSeconds,
  });

  final String downloadId;
  final String cacheKey;
  final String peerUsername;
  final String remoteFilename;
  int sizeBytes;
  final String fileExtension;

  /// Не final: загрузку без метаданных дополняет следующий startDownload.
  String? title;
  String? artist;
  int? durationSeconds;

  SoulseekTransferState state;
  int bytesReceived = 0;
  int bytesPerSecond = 0;
  String? localPath;
  int retryCount = 0;
  DateTime lastCheckpointAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool pauseRequested = false;
  bool cancelRequested = false;

  /// Промежуточная retryable-неудача: retry-loop продолжает с backoff.
  bool retrySignal = false;

  /// Мост закончил, идёт публикация `.part` в кэш.
  bool publishing = false;

  /// Слот параллельных загрузок текущей попытки (null — вне попытки).
  _SlotLease? lease;

  Completer<void>? _waiter;

  /// Поколение retry-loop ([SoulseekTransferManager._process]).
  int run = 0;

  /// Номер текущей попытки в мосте; id попытки — [bridgeId].
  int attempt = 0;
  String get bridgeId => '$downloadId#$attempt';

  /// Попытки, запущенные в мосте и ещё не приславшие терминальное событие.
  final Map<int, Completer<void>> _openAttempts = {};

  bool get attemptActive => _openAttempts.containsKey(attempt);

  void beginAttempt() {
    attempt++;
    _openAttempts[attempt] = Completer<void>();
  }

  void endAttempt(int n) {
    final c = _openAttempts.remove(n);
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Ждёт, пока прошлые попытки закроют `.part` (терминальное событие моста).
  /// Предел — на случай потерянного события: если файл ещё занят, мост
  /// вернёт retryable-ошибку.
  Future<void> previousAttemptDone() async {
    final open = _openAttempts.values.map((c) => c.future).toList();
    if (open.isEmpty) return;
    await Future.wait(open).timeout(
      const Duration(seconds: 5),
      onTimeout: () => const [],
    );
  }

  bool get isSettled =>
      state.isTerminal || pauseRequested || cancelRequested || retrySignal;

  /// Ожидание до [wake] — для текущей попытки загрузки.
  Future<void> arm() => (_waiter = Completer<void>()).future;

  void wake() {
    final w = _waiter;
    if (w != null && !w.isCompleted && isSettled) w.complete();
  }

  SoulseekTransferInfo info(
          {String? errorCode, bool retryable = false, String? message}) =>
      SoulseekTransferInfo(
        downloadId: downloadId,
        state: state,
        bytesReceived: bytesReceived,
        totalBytes: sizeBytes,
        bytesPerSecond: bytesPerSecond,
        localPath: localPath,
        errorCode: errorCode,
        retryable: retryable,
        message: message,
        title: title,
        artist: artist,
        remoteFilename: remoteFilename,
      );
}

/// Счётный семафор с изменяемым лимитом.
class _Slots {
  _Slots(this._max);

  int _max;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue();

  set max(int value) {
    _max = value;
    _drain();
  }

  /// Слот без ожидания: false — свободных нет (или есть ждущие).
  bool tryAcquire() {
    if (_active < _max && _waiters.isEmpty) {
      _active++;
      return true;
    }
    return false;
  }

  Future<void> acquire() {
    if (_active < _max && _waiters.isEmpty) {
      _active++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    _active--;
    _drain();
  }

  void _drain() {
    while (_active < _max && _waiters.isNotEmpty) {
      _active++;
      _waiters.removeFirst().complete();
    }
  }
}

/// Слот [_Slots], взятый попыткой загрузки. Пока пир держит файл в своей
/// очереди, слот отпускается ([release]) — иначе такие загрузки (очередь у
/// пира бывает многоминутной) занимают все слоты и новые стоят в локальной
/// очереди. Когда пир начинает отдавать файл, слот берётся снова, если
/// свободен ([tryReacquire]); если нет — загрузка идёт сверх лимита.
class _SlotLease {
  _SlotLease(this._slots);

  final _Slots _slots;
  bool _held = true;

  void release() {
    if (!_held) return;
    _held = false;
    _slots.release();
  }

  void tryReacquire() {
    if (!_held && _slots.tryAcquire()) _held = true;
  }
}
