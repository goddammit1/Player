// lib/sources/soulseek_desktop/soulseek_desktop_channel.dart
//
// Soulseek на Windows: реализация [SoulseekPlatformChannel] поверх моста
// внутри процесса (см. soulseek_native_bridge.dart). Здесь же то, что на
// Android живёт в Kotlin (SoulseekPlugin + ForegroundService): менеджер
// загрузок, кэш, состояние соединения.
//
// Сверх Android:
//  - переподключение после обрыва по образцу slskd (ConnectionWatchdog):
//    экспоненциальный backoff 1 с … 5 мин с jitter; не переподключаемся после
//    выхода пользователя, неверного пароля и входа тем же ником с другого
//    устройства (KickedFromServer) — последнее показывается сообщением;
//  - ленивое подключение сохранёнными учётными данными при первом поиске /
//    загрузке: соединение живёт столько же, сколько приложение.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';
import '../../core/soulseek_credentials.dart';
import '../soulseek_models.dart';
import '../soulseek_platform_channel.dart';
import 'soulseek_desktop_cache.dart';
import 'soulseek_desktop_store.dart';
import 'soulseek_native_bridge.dart';
import 'soulseek_transfer_manager.dart';

/// Сохранённые учётные данные для автоподключения (null — нет).
typedef SoulseekCredentialsLoader = Future<SoulseekCredentialPair?> Function();

class DesktopSoulseekChannel extends SoulseekPlatformChannel {
  DesktopSoulseekChannel({
    SoulseekBridgeTransport? bridge,
    SoulseekDesktopStore? store,
    Future<String> Function()? cacheDirectory,
    SoulseekCredentialsLoader? credentials,
    Duration Function(int attempt)? reconnectDelay,
    Duration Function(int attempt)? retryDelay,
  })  : _bridge = bridge ?? SoulseekNativeBridge(),
        _storeOverride = store,
        _cacheDirectory = cacheDirectory ?? defaultCacheDirectory,
        _credentials = credentials ?? SoulseekCredentials.load,
        _reconnectDelay = reconnectDelay ?? defaultReconnectDelay,
        _retryDelay = retryDelay;

  static final DesktopSoulseekChannel instance = DesktopSoulseekChannel();

  /// Сообщение при входе тем же ником с другого устройства.
  static const String kickedMessage =
      'Disconnected: this account signed in from another device';

  final SoulseekBridgeTransport _bridge;
  final SoulseekDesktopStore? _storeOverride;
  final Future<String> Function() _cacheDirectory;
  final SoulseekCredentialsLoader _credentials;
  final Duration Function(int attempt) _reconnectDelay;
  final Duration Function(int attempt)? _retryDelay;

  final StreamController<SoulseekEvent> _controller =
      StreamController<SoulseekEvent>.broadcast();

  Future<SoulseekTransferManager>? _ready;
  StreamSubscription<Map<String, dynamic>>? _bridgeSub;

  SoulseekConnectionState _state = SoulseekConnectionState.disconnected;
  String? _message;

  /// Учётные данные последнего успешного подключения — для переподключения.
  _Session? _session;

  /// Пользователь отключился сам: обрыв не переподключаем.
  bool _intentional = false;

  Future<SoulseekConnectionInfo>? _connecting;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  int _listenPort = 24150;
  int? _cacheLimitBytes;
  int? _maxParallel;

  /// Кэш Soulseek: `%LOCALAPPDATA%\com.player\player\soulseek_cache` —
  /// не %TEMP% (его чистит «Очистка диска») и не Roaming.
  static Future<String> defaultCacheDirectory() async =>
      p.join((await AppPaths.cacheDir()).path, 'soulseek_cache');

  /// slskd ConnectionWatchdog: 1 с × 2^attempt, предел 5 мин, jitter до 20%.
  static Duration defaultReconnectDelay(int attempt) {
    final seconds = math.min(300, 1 << math.min(attempt, 9));
    final jitterMs = math.Random().nextInt(seconds * 200 + 1);
    return Duration(milliseconds: seconds * 1000 + jitterMs);
  }

  @override
  bool get isAvailable => _bridge.isInstalled;

  /// Текущее состояние соединения (для индикаторов UI).
  SoulseekConnectionState get connectionState => _state;

  Future<SoulseekTransferManager> _manager() =>
      _ready ??= _init().catchError((Object e) {
        // Не кэшируем неудачу (БД ещё не открыта и т. п.): следующий вызов
        // попробует снова.
        _ready = null;
        unawaited(_bridgeSub?.cancel());
        _bridgeSub = null;
        throw e;
      });

  Future<SoulseekTransferManager> _init() async {
    final store = _storeOverride ?? SqliteSoulseekDesktopStore();
    final cache = SoulseekDesktopCache(
      store: store,
      cacheDir: await _cacheDirectory(),
      maxCacheSizeBytes:
          _cacheLimitBytes ?? SoulseekDesktopCache.defaultMaxCacheSizeBytes,
    );
    final manager = SoulseekTransferManager(
      bridge: _bridge,
      store: store,
      cache: cache,
      maxConcurrentDownloads:
          _maxParallel ?? SoulseekTransferManager.defaultMaxConcurrent,
      retryDelay: _retryDelay,
    );
    manager.events.listen((info) => _add(SoulseekTransferEvent(info)));
    _bridgeSub = _bridge.events.listen((e) => _onBridgeEvent(manager, e));
    await manager.restore();
    return manager;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  События
  // ═══════════════════════════════════════════════════════════════════

  /// Каждый подписчик сразу получает текущее состояние соединения и снимок
  /// трансферов — как onListen у EventChannel на Android.
  @override
  Stream<SoulseekEvent> get events => Stream<SoulseekEvent>.multi((c) {
        c.add(SoulseekConnectionEvent(state: _state, message: _message));
        final ready = _ready;
        if (ready != null) {
          unawaited(ready.then((m) {
            final all = m.getAllTransfers();
            if (all.isNotEmpty && !c.isClosed) {
              c.add(SoulseekTransferSnapshot(transfers: all));
            }
          }));
        }
        final sub = _controller.stream.listen(c.add, onError: c.addError);
        c.onCancel = sub.cancel;
      }, isBroadcast: true);

  @override
  Stream<SoulseekTransferEvent> get transferEvents =>
      _controller.stream.where((e) => e is SoulseekTransferEvent).cast();

  @override
  Stream<SoulseekSearchProgressEvent> get searchProgress =>
      _controller.stream.where((e) => e is SoulseekSearchProgressEvent).cast();

  @override
  Stream<SoulseekConnectionEvent> get connectionEvents =>
      events.where((e) => e is SoulseekConnectionEvent).cast();

  void _add(SoulseekEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  void _onBridgeEvent(SoulseekTransferManager manager, Map<String, dynamic> e) {
    switch (e['eventType']) {
      case 'clientStateChanged':
        final state = SoulseekConnectionState.tryParse(e['state'] as String?);
        // Во время ожидания переподключения клиент отключён, но для UI
        // это «reconnecting», а не «disconnected».
        if (state == null ||
            (_reconnectTimer != null &&
                state == SoulseekConnectionState.disconnected)) {
          return;
        }
        _setState(state, _nonEmpty(e['message']));
      case 'disconnected':
        _onDisconnected(e['errorCode'] as String?, _nonEmpty(e['message']));
      case 'searchProgress':
        _add(SoulseekEvent.fromMap(e));
      default:
        if (e['downloadId'] != null) unawaited(manager.handleBridgeEvent(e));
    }
  }

  void _setState(SoulseekConnectionState state, [String? message]) {
    if (state == _state && message == _message) return;
    _state = state;
    _message = message;
    _add(SoulseekConnectionEvent(state: state, message: message));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Соединение
  // ═══════════════════════════════════════════════════════════════════

  void _onDisconnected(String? errorCode, String? message) {
    if (_intentional || _connecting != null) {
      // Своё отключение или неудачная попытка connect — о ней сообщит
      // результат вызова.
      if (_connecting == null) _setState(SoulseekConnectionState.disconnected);
      return;
    }
    switch (errorCode) {
      case 'KickedFromServerException':
        _session = null;
        _setState(SoulseekConnectionState.disconnected, kickedMessage);
        return;
      case 'LoginRejectedException':
        _session = null;
        _setState(SoulseekConnectionState.failed, message);
        return;
    }
    if (_session == null) {
      _setState(SoulseekConnectionState.disconnected, message);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    final delay = _reconnectDelay(_reconnectAttempt++);
    if (kDebugMode) {
      debugPrint('[Soulseek] reconnecting in ${delay.inMilliseconds} ms');
    }
    _setState(SoulseekConnectionState.reconnecting);
    _reconnectTimer = Timer(delay, () async {
      final session = _session;
      if (session == null || _intentional) {
        _reconnectTimer = null;
        return;
      }
      try {
        await _connectOnce(session);
        _reconnectTimer = null;
        _reconnectAttempt = 0;
      } catch (e) {
        _reconnectTimer = null;
        if (e is SoulseekException && e.code == 'LoginRejectedException') {
          _session = null;
          _setState(SoulseekConnectionState.failed, e.message);
        } else {
          _scheduleReconnect();
        }
      }
    });
  }

  Future<SoulseekConnectionInfo> _connectOnce(_Session session) {
    final pending = _connecting;
    if (pending != null) return pending;
    final attempt = () async {
      await _manager();
      _setState(SoulseekConnectionState.connecting);
      try {
        final data = await _bridge.call('connect', jsonEncode(session.toJson()));
        final info = SoulseekConnectionInfo.fromMap(
            (jsonDecode(data ?? '{}') as Map).cast<String, dynamic>());
        _session = session;
        _setState(info.state);
        return info;
      } on SoulseekException {
        _setState(SoulseekConnectionState.failed);
        rethrow;
      }
    }();
    _connecting = attempt;
    return attempt.whenComplete(() => _connecting = null);
  }

  /// Подключение сохранёнными учётными данными, если соединения нет.
  /// Без сохранённых данных — ничего: мост ответит «not connected».
  Future<void> _ensureConnected() async {
    if (_state == SoulseekConnectionState.connected) return;
    final pending = _connecting;
    if (pending != null) {
      await pending;
      return;
    }
    if (_intentional) return;
    var session = _session;
    if (session == null) {
      final saved = await _credentials();
      if (saved == null) return;
      session = _Session(
        username: saved.username,
        password: saved.password,
        listenPort: _listenPort,
      );
    }
    // Ждущий backoff заменяем немедленной попыткой; если она не удалась,
    // watchdog должен продолжить, а не замолчать до следующего дисконнекта.
    final watchdogWasActive = _reconnectTimer != null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await _connectOnce(session);
    } catch (e) {
      final loginRejected =
          e is SoulseekException && e.code == 'LoginRejectedException';
      if (watchdogWasActive && !_intentional && !loginRejected) {
        _scheduleReconnect();
      }
      rethrow;
    }
  }

  @override
  Future<bool> startService() async {
    await _manager();
    return true;
  }

  @override
  Future<bool> stopService() => disconnect();

  @override
  Future<bool> updateNativeSettings({
    int? listenPort,
    int? cacheLimitMb,
    int? maxParallelDownloads,
    String? username,
  }) async {
    if (listenPort != null) _listenPort = listenPort;
    if (cacheLimitMb != null) {
      _cacheLimitBytes = cacheLimitMb * 1024 * 1024;
    }
    if (maxParallelDownloads != null) _maxParallel = maxParallelDownloads;
    // Менеджер ещё не создан — значения применятся при инициализации.
    final ready = _ready;
    if (ready != null) {
      final manager = await ready;
      if (maxParallelDownloads != null) {
        manager.maxConcurrentDownloads = maxParallelDownloads;
      }
      if (cacheLimitMb != null) {
        await manager.cache.updateMaxCacheSizeBytes(_cacheLimitBytes!);
      }
    }
    return true;
  }

  @override
  Future<bool> configureAccount({
    required String username,
    int listenPort = 24150,
  }) async {
    _listenPort = listenPort;
    return true;
  }

  @override
  Future<SoulseekConnectionInfo> connect({
    required String username,
    required String password,
    int listenPort = 24150,
    bool enableListener = true,
    int messageTimeoutMs = 30000,
  }) {
    _intentional = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _listenPort = listenPort;
    return _connectOnce(_Session(
      username: username,
      password: password,
      listenPort: listenPort,
      enableListener: enableListener,
      messageTimeoutMs: messageTimeoutMs,
    ));
  }

  @override
  Future<bool> disconnect() async {
    _intentional = true;
    _session = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final ready = _ready;
    if (ready != null) {
      // Загрузки встают на паузу (resume после подключения), а не
      // отменяются вместе с клиентом.
      await (await ready).pauseAll();
      await _bridge.call('disconnect', '');
    }
    _setState(SoulseekConnectionState.disconnected);
    return true;
  }

  @override
  Future<SoulseekConnectionState?> getConnectionState() async => _state;

  /// Выход из приложения: загрузки → PAUSED, клиент освобождается.
  Future<void> shutdown() async {
    final ready = _ready;
    if (ready == null) return;
    _intentional = true;
    _reconnectTimer?.cancel();
    await (await ready).shutdown();
    final bridge = _bridge;
    if (bridge is SoulseekNativeBridge) bridge.shutdown();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Поиск
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    int timeoutMs = 10000,
    int idleTimeoutMs = 2500,
    int responseLimit = 250,
    int fileLimit = 2000,
    SoulseekSearchFilters filters = SoulseekSearchFilters.empty,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    await _manager();
    await _ensureConnected();
    final data = await _bridge.call('search', jsonEncode({
      'requestId': requestId,
      'query': q,
      'timeoutMs': timeoutMs,
      'idleTimeoutMs': idleTimeoutMs,
      'responseLimit': responseLimit,
      'fileLimit': fileLimit,
      'filters': filters.toMap(),
    }));
    return _results(data);
  }

  @override
  Future<void> cancelSearch(String requestId) async {
    if (_ready == null) return;
    try {
      await _bridge.call('cancelSearch', requestId);
    } on SoulseekException catch (e) {
      debugPrint('[Soulseek] cancelSearch failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<List<SoulseekSearchResult>> getDirectoryContents({
    required String username,
    required String directory,
    int timeoutMs = 20000,
  }) async {
    await _manager();
    await _ensureConnected();
    final data = await _bridge.call('getDirectoryContents', jsonEncode({
      'username': username,
      'directory': directory,
      'timeoutMs': timeoutMs,
    }));
    return _results(data);
  }

  static List<SoulseekSearchResult> _results(String? data) {
    if (data == null || data.isEmpty) return const [];
    return (jsonDecode(data) as List)
        .map((m) =>
            SoulseekSearchResult.fromMap((m as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Загрузки
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<SoulseekDownloadResult> startDownload({
    required String downloadId,
    required String peerUsername,
    required String remoteFilename,
    required int sizeBytes,
    required String cacheKey,
    String fileExtension = 'dat',
    String? title,
    String? artist,
    int? durationSeconds,
  }) async {
    final manager = await _manager();
    // Готовый файл подключения не требует.
    if (await manager.cache.getCacheEntry(cacheKey) == null) {
      await _ensureConnected();
    }
    return manager.startDownload(
      downloadId: downloadId,
      peerUsername: peerUsername,
      remoteFilename: remoteFilename,
      sizeBytes: sizeBytes,
      cacheKey: cacheKey,
      fileExtension: fileExtension,
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
  }

  @override
  Future<bool> pauseDownload(String downloadId) async {
    await (await _manager()).pauseDownload(downloadId);
    return true;
  }

  @override
  Future<bool> resumeDownload(String downloadId) async {
    final manager = await _manager();
    await _ensureConnected();
    await manager.resumeDownload(downloadId);
    return true;
  }

  @override
  Future<bool> cancelDownload(String downloadId) async {
    await (await _manager()).cancelDownload(downloadId);
    return true;
  }

  @override
  Future<bool> retryDownload(String downloadId) async {
    final manager = await _manager();
    final state = manager.getTransfer(downloadId)?.state;
    // Неподходящий трансфер — без лишнего подключения.
    if (state != SoulseekTransferState.failed &&
        state != SoulseekTransferState.cancelled) {
      return false;
    }
    await _ensureConnected();
    return manager.retryDownload(downloadId);
  }

  @override
  Future<int> clearFinishedTransfers() async =>
      (await _manager()).clearFinishedTransfers();

  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async =>
      (await _manager()).getTransfer(downloadId);

  @override
  Future<List<SoulseekTransferInfo>> getActiveTransfers({
    bool includeTerminal = false,
  }) async {
    final manager = await _manager();
    return includeTerminal
        ? manager.getAllTransfers()
        : manager.getActiveTransfers();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Кэш
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async =>
      (await _manager()).cache.getCacheEntry(cacheKey);

  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async =>
      (await _manager()).cache.getAllCacheEntries();

  @override
  Future<bool> removeCache(String cacheKey) async =>
      (await _manager()).cache.removeCache(cacheKey);

  @override
  Future<bool> pinCache(String cacheKey, {required bool pinned}) async {
    await (await _manager()).cache.pin(cacheKey, pinned: pinned);
    return true;
  }

  @override
  Future<int> cleanupCache() async => (await _manager()).cache.cleanup();

  @override
  Future<bool> setSharingDirectory({
    bool? enableListener,
    int? listenPort,
    int? maximumUploadSpeed,
    int? maximumDownloadSpeed,
  }) async {
    await _bridge.call('configureSharing', jsonEncode({
      'enableListener': ?enableListener,
      'listenPort': ?listenPort,
      'maximumUploadSpeed': ?maximumUploadSpeed,
      'maximumDownloadSpeed': ?maximumDownloadSpeed,
    }));
    return true;
  }

  @visibleForTesting
  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await _bridgeSub?.cancel();
    await _controller.close();
  }

  static String? _nonEmpty(Object? v) =>
      v is String && v.isNotEmpty ? v : null;
}

class _Session {
  const _Session({
    required this.username,
    required this.password,
    required this.listenPort,
    this.enableListener = true,
    this.messageTimeoutMs = 30000,
  });

  final String username;
  final String password;
  final int listenPort;
  final bool enableListener;
  final int messageTimeoutMs;

  Map<String, Object> toJson() => {
        'username': username,
        'password': password,
        'listenPort': listenPort,
        'enableListener': enableListener,
        'messageTimeoutMs': messageTimeoutMs,
      };
}
