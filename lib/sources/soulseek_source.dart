// lib/sources/soulseek_source.dart
//
// Фаза 3 — реализация [TrackSource] для Soulseek P2P-сети.
//
// Soulseek не имеет стриминговых URL: файлы скачиваются с пиров целиком
// и кэшируются на устройстве (нативный кэш SoulseekCacheManager, Фаза 2).
// Воспроизведение — из локального file:// пути.
//
// Поток resolveStreamUrl → ensureLocalFile → AudioSource:
//   1. Вычислить cacheKey (sha256, детерминированный, совпадает с Kotlin-стороной).
//   2. getCacheEntry(cacheKey) → если complete, вернуть localPath.
//   3. startDownload() → если cacheHit, вернуть path; иначе ждать
//      transfer-событие (completed) из EventChannel.
//   4. createAudioSource → AudioSource.uri(Uri.file(localPath)).
//
// Паттерны следуют MuzmoSource (эталонная реализация): DI Channel через
// конструктор, проверка офлайн-кэша через createOfflineAudioSource,
// dispose без остановки foreground service.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/track.dart';
import 'offline_audio_source.dart' as offline;
import 'soulseek_models.dart';
import 'soulseek_platform_channel.dart';
import 'track_source.dart';

/// Минимальный контракт платформенного канала, необходимый [SoulseekSource].
///
/// Выделен из [SoulseekPlatformChannel] для dependency injection в тестах:
/// тесты передают фейковую реализацию в конструктор [SoulseekSource.new],
/// не трогая реальный MethodChannel/EventChannel.
///
/// Значения по умолчанию для optional-параметров указаны в реализации
/// [SoulseekPlatformChannel]; вызывающий код [SoulseekSource] передаёт
/// их явно, чтобы контракт не зависел от defaults.
abstract class SoulseekChannel {
  /// True, если Soulseek доступен на текущей платформе (только Android).
  bool get isAvailable;

  /// Выполняет поиск по запросу с фильтрами.
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int responseLimit,
    required SoulseekSearchFilters filters,
  });

  /// Возвращает запись о кэшированном файле (или null, если файла нет).
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey);

  /// Запускает загрузку файла (или возвращает путь к кэшированному).
  Future<SoulseekDownloadResult> startDownload({
    required String downloadId,
    required String peerUsername,
    required String remoteFilename,
    required int sizeBytes,
    required String cacheKey,
    required String fileExtension,
  });

  /// Возвращает информацию о трансфере по downloadId (или null).
  Future<SoulseekTransferInfo?> getTransfer(String downloadId);

  /// Поток transfer-событий (прогресс / смена состояния / завершение).
  Stream<SoulseekTransferEvent> get transferEvents;
}

class SoulseekSource implements TrackSource {
  static const String sourceId = 'soulseek';

  final SoulseekChannel _channel;

  /// Настраиваемые фильтры поиска (UI Фазы 4 может менять перед вызовом search).
  SoulseekSearchFilters searchFilters = SoulseekSearchFilters.empty;

  /// Активные подписки на event stream — для отмены в [dispose].
  final Set<StreamSubscription<SoulseekTransferEvent>> _activeSubscriptions = {};

  /// SharedPreferences-ключ для индекса известных cache keys.
  static const _cacheIndexKey = 'soulseek_cache_index';

  /// Индекс известных cache keys (для UI cache sheet).
  /// Platform channel не имеет команды «список всех кэш-записей»,
  /// поэтому Dart-сторона ведёт собственный индекс в SharedPreferences.
  final Set<String> _knownCacheKeys = {};

  SoulseekSource({SoulseekChannel? channel})
      : _channel = channel ?? SoulseekPlatformChannel.instance {
    _loadCacheIndex();
  }

  /// Загружает индекс cache keys из SharedPreferences.
  Future<void> _loadCacheIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_cacheIndexKey) ?? const [];
      _knownCacheKeys
        ..clear()
        ..addAll(raw);
    } catch (_) {
      // Игнорируем — индекс опционален.
    }
  }

  /// Добавляет [cacheKey] в индекс и персистит в SharedPreferences.
  Future<void> _recordCacheKey(String cacheKey) async {
    if (cacheKey.isEmpty) return;
    if (_knownCacheKeys.add(cacheKey)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _cacheIndexKey,
          _knownCacheKeys.toList(),
        );
      } catch (_) {}
    }
  }

  /// Удаляет [cacheKey] из индекса и персистит.
  Future<void> _removeCacheKey(String cacheKey) async {
    if (_knownCacheKeys.remove(cacheKey)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _cacheIndexKey,
          _knownCacheKeys.toList(),
        );
      } catch (_) {}
    }
  }

  /// Возвращает список всех известных cache keys (для UI cache sheet).
  List<String> get knownCacheKeys => _knownCacheKeys.toList();

  /// Удаляет [cacheKey] из индекса (вызывается UI cache sheet при
  /// обнаружении, что файл уже удалён нативно).
  void forgetCacheKey(String cacheKey) {
    _removeCacheKey(cacheKey);
  }

  /// Очищает весь индекс cache keys (при «Clear all» в cache sheet).
  void clearCacheIndex() {
    _knownCacheKeys.clear();
    _persistCacheIndex();
  }

  Future<void> _persistCacheIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _cacheIndexKey,
        _knownCacheKeys.toList(),
      );
    } catch (_) {}
  }

  @override
  String get id => sourceId;

  @override
  String get displayName => 'Soulseek';

  // ═══════════════════════════════════════════════════════════════════
  //  search
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    // На не-Android платформах Soulseek недоступен — возвращаем пустой список,
    // чтобы SourceRegistry.searchable не падал.
    if (!_channel.isAvailable) return const [];

    final q = query.trim();
    if (q.isEmpty) return const [];

    final requestId = const Uuid().v4();

    try {
      final results = await _channel.search(
        requestId: requestId,
        query: q,
        timeoutMs: 15000,
        responseLimit: 250,
        filters: searchFilters,
      );

      // Пост-фильтрация на Dart-стороне (дублирование native-фильтров).
      final filtered = results.where((r) => searchFilters.matches(r)).toList();

      // Дедупликация по filename + size.
      final seen = <String>{};
      final deduped = <SoulseekSearchResult>[];
      for (final r in filtered) {
        final key = '${r.filename}|${r.sizeBytes}';
        if (seen.add(key)) {
          deduped.add(r);
        }
      }

      final tracks = deduped.take(limit).map(_resultToTrack).toList();

      if (kDebugMode) {
        debugPrint('[Soulseek] search "$q": ${results.length} raw, '
            '${filtered.length} filtered, ${tracks.length} after dedup+limit');
      }

      return tracks;
    } on SoulseekException catch (e) {
      if (kDebugMode) debugPrint('[Soulseek] search failed: $e');
      return const [];
    } on UnsupportedError {
      return const [];
    }
  }

  /// Маппинг [SoulseekSearchResult] → [Track].
  Track _resultToTrack(SoulseekSearchResult result) {
    final cacheKey =
        computeCacheKey(result.username, result.filename, result.sizeBytes);

    return Track(
      // resultId из C# bridge уникален; fallback на cacheKey.
      id: result.resultId.isNotEmpty ? result.resultId : cacheKey,
      sourceId: sourceId,
      title: extractTitle(result.filename),
      artist: extractArtist(result.filename),
      duration: result.durationSeconds != null
          ? Duration(seconds: result.durationSeconds!)
          : null,
      artworkUrl: null,
      qualityScore: result.bitrate ?? 0,
      qualityLabel:
          qualityLabel(result.extension, result.bitrate, result.bitDepth, result.sampleRate),
      extra: <String, dynamic>{
        'peerUsername': result.username,
        'remoteFilename': result.filename,
        'sizeBytes': result.sizeBytes,
        'cacheKey': cacheKey,
        'extension': result.extension,
        'bitrate': result.bitrate,
        'sampleRate': result.sampleRate,
        'bitDepth': result.bitDepth,
        'durationSeconds': result.durationSeconds,
        'hasFreeUploadSlot': result.freeUploadSlots > 0,
        'uploadSpeed': result.uploadSpeed,
        'queueLength': result.queueLength,
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  resolveStreamUrl — обеспечение локального файла
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final cacheKey = _getOrCreateCacheKey(track);

    // 1. Проверка кэша: файл уже скачан и complete?
    final entry = await _channel.getCacheEntry(cacheKey);
    if (entry != null && entry.complete) {
      if (kDebugMode) debugPrint('[Soulseek] cache hit: $cacheKey → ${entry.localPath}');
      return entry.localPath;
    }

    // 2. Запуск загрузки (или присоединение к идущей).
    final peerUsername = track.extra['peerUsername'] as String?;
    final remoteFilename = track.extra['remoteFilename'] as String?;
    final sizeBytes = _asInt(track.extra['sizeBytes']);
    final extension = (track.extra['extension'] as String?) ?? 'dat';

    if (peerUsername == null || remoteFilename == null || sizeBytes <= 0) {
      throw StateError(
        'SoulseekSource: track "$track" missing required extra fields '
        '(peerUsername, remoteFilename, sizeBytes) for download',
      );
    }

    // Детерминированный downloadId — совпадает при повторных запросах того же
    // файла, что позволяет Kotlin-стороне сделать dedupe и вернуть тот же ID.
    final downloadId = 'dl_$cacheKey';

    if (kDebugMode) {
      debugPrint('[Soulseek] startDownload: $downloadId '
          'peer=$peerUsername file=$remoteFilename size=$sizeBytes');
    }

    final result = await _channel.startDownload(
      downloadId: downloadId,
      peerUsername: peerUsername,
      remoteFilename: remoteFilename,
      sizeBytes: sizeBytes,
      cacheKey: cacheKey,
      fileExtension: extension,
    );

    // Cache hit — файл уже complete (мог появиться между шагами 1 и 2).
    if (result.cacheHit) {
      if (kDebugMode) debugPrint('[Soulseek] startDownload cache hit: ${result.result}');
      return result.result;
    }

    // 3. Ждём завершения загрузки через event stream.
    //    result.result — downloadId (может отличаться при dedupe).
    final actualDownloadId = result.result;
    return _waitForDownloadComplete(actualDownloadId);
  }

  /// Ждёт transfer-событие completed/failed/cancelled для [downloadId].
  ///
  /// Подписывается на event stream, затем проверяет текущее состояние через
  /// getTransfer (race-safe: если событие уже пришло, completer уже completed).
  Future<String> _waitForDownloadComplete(
    String downloadId, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final completer = Completer<String>();

    void handleInfo(SoulseekTransferInfo info) {
      if (info.downloadId != downloadId) return;
      switch (info.state) {
        case SoulseekTransferState.completed:
          final path = info.localPath;
          if (path != null && path.isNotEmpty) {
            if (!completer.isCompleted) completer.complete(path);
          } else if (!completer.isCompleted) {
            completer.completeError(const SoulseekException(
              'DOWNLOAD_COMPLETE_NO_PATH',
              'Download completed but no localPath in event',
            ));
          }
        case SoulseekTransferState.failed:
          if (!completer.isCompleted) {
            completer.completeError(SoulseekException(
              info.errorCode ?? 'DOWNLOAD_FAILED',
              info.message ?? 'Download failed',
              retryable: info.retryable,
            ));
          }
        case SoulseekTransferState.cancelled:
          if (!completer.isCompleted) {
            completer.completeError(SoulseekException(
              'DOWNLOAD_CANCELLED',
              info.message ?? 'Download cancelled',
            ));
          }
        default:
          // Промежуточные состояния (queued, downloading, …) — игнорируем.
          break;
      }
    }

    // cacheKey для записи в индекс после завершения.
    final cacheKeyForIndex = downloadId.replaceFirst('dl_', '');

    final sub = _channel.transferEvents.listen(
      (event) {
        handleInfo(event.transfer);
        // Записываем cacheKey в индекс при успешном завершении.
        if (event.transfer.state == SoulseekTransferState.completed) {
          _recordCacheKey(cacheKeyForIndex);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    _activeSubscriptions.add(sub);

    // Проверяем текущее состояние после подписки (race-safe).
    try {
      final current = await _channel.getTransfer(downloadId);
      if (current != null) {
        handleInfo(current);
        if (current.state == SoulseekTransferState.completed) {
          _recordCacheKey(cacheKeyForIndex);
        }
      }
    } catch (_) {
      // Игнорируем — будем ждать событие.
    }

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw const SoulseekException(
          'DOWNLOAD_TIMEOUT',
          'Download timed out',
          retryable: true,
        ),
      );
    } finally {
      _activeSubscriptions.remove(sub);
      await sub.cancel();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  createAudioSource
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    // 1. Проверка офлайн-кэша (YoutubeCache) — следует паттерну MuzmoSource.
    //    Soulseek-файлы лежат в отдельном native-кэше (soulseek_cache/),
    //    поэтому createOfflineAudioSource вернёт null для них. Но паттерн
    //    сохранён для консистентности и на случай будущих изменений.
    final offlineSource = await offline.createOfflineAudioSource(track);
    if (offlineSource != null) return offlineSource;

    // 2. Обеспечить локальный файл (кэш Soulseek → скачать если нужно).
    final localPath = await resolveStreamUrl(track);

    // 3. AudioSource из локального file:// пути — без сетевых URL.
    return AudioSource.uri(Uri.file(localPath));
  }

  /// Предзагрузка: запускает скачивание в фоне, не дожидаясь завершения.
  ///
  /// В отличие от [createAudioSource], не возвращает AudioSource и не блокирует
  /// до полного скачивания — просто инициирует загрузку, чтобы к моменту
  /// воспроизведения файл уже был в кэше.
  @override
  Future<void> prefetch(Track track) async {
    if (!_channel.isAvailable) return;

    final cacheKey = _getOrCreateCacheKey(track);

    // Если уже в кэше — ничего не делаем.
    final entry = await _channel.getCacheEntry(cacheKey);
    if (entry != null && entry.complete) return;

    final peerUsername = track.extra['peerUsername'] as String?;
    final remoteFilename = track.extra['remoteFilename'] as String?;
    final sizeBytes = _asInt(track.extra['sizeBytes']);
    final extension = (track.extra['extension'] as String?) ?? 'dat';

    if (peerUsername == null || remoteFilename == null || sizeBytes <= 0) {
      return;
    }

    final downloadId = 'dl_$cacheKey';

    try {
      await _channel.startDownload(
        downloadId: downloadId,
        peerUsername: peerUsername,
        remoteFilename: remoteFilename,
        sizeBytes: sizeBytes,
        cacheKey: cacheKey,
        fileExtension: extension,
      );
      // Не ждём завершения — загрузка идёт в фоне через foreground service.
    } on SoulseekException catch (e) {
      if (kDebugMode) debugPrint('[Soulseek] prefetch failed: $e');
    } on UnsupportedError {
      // Не Android — игнорируем.
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  resolveBitrate / resolveArtwork
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<int?> resolveBitrate(Track track) async {
    final fromExtra = track.extra['bitrate'] as int?;
    if (fromExtra != null && fromExtra > 0) return fromExtra;
    return track.qualityScore;
  }

  /// Soulseek не предоставляет обложек — всегда null (фолбэк на Genius/iTunes).
  @override
  Future<String?> resolveArtwork(Track track) async => null;

  // ═══════════════════════════════════════════════════════════════════
  //  dispose
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<void> dispose() async {
    // Отписываемся от всех активных event-подписок.
    // НЕ останавливаем foreground service — он может использоваться
    // другими компонентами (активные загрузки из UI).
    final subs = _activeSubscriptions.toList();
    _activeSubscriptions.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Helpers — cacheKey
  // ═══════════════════════════════════════════════════════════════════

  /// Извлекает cacheKey из [track.extra] или вычисляет.
  String _getOrCreateCacheKey(Track track) {
    final existing = track.extra['cacheKey'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;

    final peerUsername = track.extra['peerUsername'] as String?;
    final remoteFilename = track.extra['remoteFilename'] as String?;
    final sizeBytes = _asInt(track.extra['sizeBytes']);

    if (peerUsername == null || remoteFilename == null || sizeBytes <= 0) {
      throw StateError(
        'SoulseekSource: track "${track.globalId}" missing required extra fields '
        '(peerUsername, remoteFilename, sizeBytes) for cacheKey computation',
      );
    }

    return computeCacheKey(peerUsername, remoteFilename, sizeBytes);
  }

  /// Вычисляет детерминированный cacheKey =
  /// sha256("soulseek\0peerUsername\0remoteFilename\0sizeBytes").
  ///
  /// Должен совпадать с [SoulseekCacheManager.computeCacheKey] на Kotlin-стороне:
  /// `"$sourceId\0$peerUsername\0$remoteFilename\0$sizeBytes"`.
  @visibleForTesting
  static String computeCacheKey(
    String peerUsername,
    String remoteFilename,
    int sizeBytes,
  ) {
    final input = 'soulseek\x00$peerUsername\x00$remoteFilename\x00$sizeBytes';
    return sha256.convert(utf8.encode(input)).toString();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Helpers — извлечение title / artist из Soulseek filename
  // ═══════════════════════════════════════════════════════════════════

  /// Извлекает название трека из полного пути Soulseek.
  ///
  /// Примеры:
  /// - `Artist - Title.flac` → "Title"
  /// - `01 - Title.flac` → "Title"
  /// - `C:\Music\Artist\Album\01 - Title.flac` → "Title"
  /// - `C:\Music\Artist\Album\Title.flac` → "Title"
  @visibleForTesting
  String extractTitle(String filename) {
    final basename = basenameWithoutExt(filename);

    final sep = findSeparator(basename);
    if (sep != null) {
      final before = basename.substring(0, sep.$1).trim();
      final after = basename.substring(sep.$1 + sep.$2).trim();
      // Если "before" — номер трека (01, 02…), возвращаем "after".
      if (isTrackNumber(before)) {
        return after.isNotEmpty ? after : basename;
      }
      return after.isNotEmpty ? after : basename;
    }

    return basename;
  }

  /// Извлекает исполнителя из полного пути Soulseek.
  ///
  /// Стратегии (по приоритету):
  /// 1. "Artist - Title.flac" → "Artist"
  /// 2. `…/Artist/Album/01 - Title.flac` → "Artist" (родительский каталог)
  /// 3. `…/Artist - Title.flac` → "Artist" (каталог-родитель)
  /// 4. Fallback → "Unknown"
  @visibleForTesting
  String extractArtist(String filename) {
    final normalized = filename.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((p) => p.isNotEmpty).toList();

    // 1. "Artist - Title" в basename.
    if (parts.isNotEmpty) {
      final basename = removeExtension(parts.last);
      final sep = findSeparator(basename);
      if (sep != null) {
        final before = basename.substring(0, sep.$1).trim();
        if (!isTrackNumber(before) && before.isNotEmpty) {
          return before;
        }
      }
    }

    // 2/3. Каталог-родитель как исполнитель.
    //   …/Artist/Album/01 - Title.flac → parts[-3] = Artist
    //   …/Artist/01 - Title.flac       → parts[-2] = Artist
    if (parts.length >= 3) {
      return parts[parts.length - 3];
    }
    if (parts.length == 2) {
      return parts[parts.length - 2];
    }

    return 'Unknown';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Helpers — quality label
  // ═══════════════════════════════════════════════════════════════════

  /// Строит метку качества из расширения и атрибутов аудио.
  ///
  /// Примеры: "FLAC 24/96", "MP3 320", "FLAC 16/44.1", "WAV", "AAC".
  @visibleForTesting
  String qualityLabel(
    String extension,
    int? bitrate,
    int? bitDepth,
    int? sampleRate,
  ) {
    final ext = extension.toLowerCase();

    switch (ext) {
      case 'flac':
      case 'alac':
      case 'wav':
      case 'ape':
      case 'wv':
        if (bitDepth != null && sampleRate != null) {
          return '${ext.toUpperCase()} $bitDepth/${sampleRateToKHz(sampleRate)}';
        }
        if (bitDepth != null) {
          return '${ext.toUpperCase()} ${bitDepth}bit';
        }
        return ext.toUpperCase();
      case 'mp3':
        return (bitrate != null && bitrate > 0) ? 'MP3 $bitrate' : 'MP3';
      case 'aac':
      case 'm4a':
        return (bitrate != null && bitrate > 0)
            ? '${ext.toUpperCase()} $bitrate'
            : ext.toUpperCase();
      case 'ogg':
      case 'oga':
        return (bitrate != null && bitrate > 0) ? 'OGG $bitrate' : 'OGG';
      case 'opus':
        return (bitrate != null && bitrate > 0) ? 'OPUS $bitrate' : 'OPUS';
      default:
        return ext.isNotEmpty ? ext.toUpperCase() : 'AUDIO';
    }
  }

  /// Конвертирует sample rate в kHz строку.
  /// Обрабатывает как Hz (44100), так и kHz (44) на входе.
  @visibleForTesting
  String sampleRateToKHz(int sampleRate) {
    if (sampleRate >= 1000) {
      final kHz = sampleRate / 1000.0;
      if (kHz == kHz.roundToDouble()) {
        return kHz.round().toString();
      }
      return kHz.toStringAsFixed(1);
    }
    return sampleRate.toString();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Helpers — утилиты для разбора имён файлов
  // ═══════════════════════════════════════════════════════════════════

  /// Возвращает последний компонент пути без расширения.
  @visibleForTesting
  String basenameWithoutExt(String filename) {
    final normalized = filename.replaceAll('\\', '/');
    final lastSlash = normalized.lastIndexOf('/');
    String basename =
        lastSlash >= 0 ? normalized.substring(lastSlash + 1) : normalized;
    return removeExtension(basename);
  }

  /// Удаляет расширение из имени файла.
  @visibleForTesting
  String removeExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot > 0) return filename.substring(0, lastDot);
    return filename;
  }

  /// Ищет разделитель " - " / " – " / " — " в [text].
  /// Возвращает (index, separatorLength) или null.
  @visibleForTesting
  (int, int)? findSeparator(String text) {
    for (final sep in [' - ', ' – ', ' — ']) {
      final i = text.indexOf(sep);
      if (i > 0) return (i, sep.length);
    }
    return null;
  }

  /// Проверяет, является ли строка номером трека ("01", "1", "01.", "01)").
  @visibleForTesting
  bool isTrackNumber(String s) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) return false;
    final cleaned = trimmed.replaceAll(RegExp(r'[.\)\]]'), '');
    return int.tryParse(cleaned) != null;
  }

  /// Безопасное преобразование dynamic → int (для значений из extra Map).
  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }
}
