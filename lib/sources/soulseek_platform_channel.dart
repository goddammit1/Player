// lib/sources/soulseek_platform_channel.dart
//
// Фаза 3 — Dart-обёртка над MethodChannel/EventChannel для Soulseek.
//
// Типизированные Dart-методы для всех команд контракта `soulseek/methods`
// (Фаза 2: SoulseekPlugin.kt) и Stream событий из `soulseek/events`.
//
// Обработка ошибок: PlatformException → [SoulseekException].
// Проверка платформы: только Android (на других — [UnsupportedError]).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'soulseek_models.dart';
import 'soulseek_source.dart' show SoulseekChannel;

/// Обёртка над platform channels для Soulseek.
///
/// Singleton: один экземпляр на всё приложение. MethodChannel и EventChannel
/// создаются один раз и переиспользуются.
class SoulseekPlatformChannel implements SoulseekChannel {
  SoulseekPlatformChannel._() {
    // EventChannel отдаёт JSON-строки (Kotlin sink.success(jsonString)).
    // Парсим каждую в типизированное событие.
    _eventsStream = _events.receiveBroadcastStream().map((raw) {
      if (raw is String) {
        return SoulseekEvent.fromJsonString(raw);
      }
      if (raw is Map) {
        return SoulseekEvent.fromMap(raw.cast<String, dynamic>());
      }
      return SoulseekUnknownEvent('raw', {'raw': raw.toString()});
    });
  }

  static final SoulseekPlatformChannel instance = SoulseekPlatformChannel._();

  static const MethodChannel _method = MethodChannel('soulseek/methods');
  static const EventChannel _events = EventChannel('soulseek/events');

  late final Stream<SoulseekEvent> _eventsStream;

  // ═══════════════════════════════════════════════════════════════════
  //  Платформенная проверка
  // ═══════════════════════════════════════════════════════════════════

  /// True, если Soulseek доступен на текущей платформе (только Android).
  @override
  bool get isAvailable => defaultTargetPlatform == TargetPlatform.android;

  void _requireAndroid() {
    if (!isAvailable) {
      throw UnsupportedError('Soulseek is only available on Android');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  EventChannel — Stream событий
  // ═══════════════════════════════════════════════════════════════════

  /// Поток типизированных событий Soulseek (transfer, connection, snapshot).
  ///
  /// При подписке Kotlin-сторона отправляет snapshot активных трансферов.
  Stream<SoulseekEvent> get events {
    _requireAndroid();
    return _eventsStream;
  }

  /// Удобный под-стрим: только transfer-события (прогресс / состояния).
  @override
  Stream<SoulseekTransferEvent> get transferEvents {
    _requireAndroid();
    return _eventsStream
        .where((e) => e is SoulseekTransferEvent)
        .cast<SoulseekTransferEvent>();
  }

  /// Удобный под-стрим: только connection-события.
  Stream<SoulseekConnectionEvent> get connectionEvents {
    _requireAndroid();
    return _eventsStream
        .where((e) => e is SoulseekConnectionEvent)
        .cast<SoulseekConnectionEvent>();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Service lifecycle
  // ═══════════════════════════════════════════════════════════════════

  /// Запускает foreground service и привязывается к нему.
  /// Должен вызываться до любых других команд.
  Future<bool> startService() async {
    _requireAndroid();
    final result = await _invoke<bool>('startService', null);
    return result ?? false;
  }

  /// Останавливает foreground service и отвязывается.
  Future<bool> stopService() async {
    _requireAndroid();
    final result = await _invoke<bool>('stopService', null);
    return result ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Account / Connection
  // ═══════════════════════════════════════════════════════════════════

  /// Фаза B (разрыв №3): проталкивает настройки из Dart-БД в нативную
  /// soulseek.db, чтобы foreground service работал с теми же значениями,
  /// что показывает UI:
  ///  - [listenPort] → `listen_port`;
  ///  - [cacheLimitMb] → `max_cache_size` (натив хранит байты, конвертация
  ///    MB → bytes на Kotlin-стороне; 0 = unlimited);
  ///  - [maxParallelDownloads] → `max_concurrent_downloads`;
  ///  - [username] → `username` (non-secret).
  ///
  /// Натив пишет в БД без старта foreground service; если сервис уже
  /// работает — применяет лимит кэша на лету.
  ///
  /// Безопасен: на не-Android — no-op (false + лог); ошибки платформы НЕ
  /// бросаются наружу — возвращается false (синк best-effort, настройки
  /// уже сохранены в Dart-БД вызывающим кодом).
  Future<bool> updateNativeSettings({
    int? listenPort,
    int? cacheLimitMb,
    int? maxParallelDownloads,
    String? username,
  }) async {
    if (!isAvailable) {
      debugPrint(
        '[Soulseek] updateNativeSettings skipped: '
        'not available on this platform',
      );
      return false;
    }
    final args = <String, dynamic>{
      'listenPort': ?listenPort,
      'cacheLimitMb': ?cacheLimitMb,
      'maxParallelDownloads': ?maxParallelDownloads,
      'username': ?username,
    };
    try {
      final result = await _invoke<bool>('updateNativeSettings', args);
      return result ?? false;
    } on SoulseekException catch (e) {
      debugPrint(
        '[Soulseek] updateNativeSettings failed: ${e.code} ${e.message}',
      );
      return false;
    }
  }

  /// Сохраняет учётные данные и параметры listener (без подключения).
  ///
  /// [username] — имя пользователя Soulseek.
  /// [listenPort] — порт для входящих peer-соединений (по умолчанию 24150,
  /// как SoulseekSettingsRepository.defaultListenPort).
  Future<bool> configureAccount({
    required String username,
    int listenPort = 24150,
  }) async {
    _requireAndroid();
    final result = await _invoke<bool>('configureAccount', {
      'account': {
        'username': username,
        'listenPort': listenPort,
      },
    });
    return result ?? false;
  }

  /// Подключается к серверу Soulseek с указанными учётными данными.
  ///
  /// Блокирует до завершения логина (несколько секунд).
  /// Возвращает состояние соединения после логина.
  Future<SoulseekConnectionInfo> connect({
    required String username,
    required String password,
    int listenPort = 24150,
    bool enableListener = true,
    int messageTimeoutMs = 30000,
  }) async {
    _requireAndroid();
    final result = await _invoke<Map>('connect', {
      'account': {
        'username': username,
        'password': password,
        'listenPort': listenPort,
        'enableListener': enableListener,
        'messageTimeoutMs': messageTimeoutMs,
      },
    });
    if (result == null) {
      throw const SoulseekException('EMPTY_RESPONSE', 'connect returned null');
    }
    return SoulseekConnectionInfo.fromMap(result.cast<String, dynamic>());
  }

  /// Отключается от сервера (dispose bridge).
  Future<bool> disconnect() async {
    _requireAndroid();
    final result = await _invoke<bool>('disconnect', null);
    return result ?? false;
  }

  /// P2: актуальное состояние коннекта из нативного transferManager.
  ///
  /// Вызывается при входе на страницу настроек: connectionEvents приходят
  /// только при изменениях, поэтому повторное открытие страницы иначе
  /// показывало бы устаревший Disconnected при живом соединении.
  Future<SoulseekConnectionState> getConnectionState() async {
    _requireAndroid();
    final result = await _invoke<String>('getConnectionState', null);
    return SoulseekConnectionState.fromString(result);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Search
  // ═══════════════════════════════════════════════════════════════════

  /// Выполняет поиск по запросу с фильтрами.
  ///
  /// [requestId] — уникальный ID запроса (генерируется вызывающим кодом).
  /// [timeoutMs] — жёсткий общий бюджет поиска (по умолчанию 10000 мс).
  /// [idleTimeoutMs] — «окно тишины» после первого ответа (по умолчанию 2500 мс).
  /// [responseLimit] — максимальное количество ответов (по умолчанию 100).
  /// [fileLimit] — досрочное завершение по числу файлов (по умолчанию 200).
  /// [filters] — поисковые фильтры (расширения, размер, битрейт и т.д.).
  ///
  /// Возвращает список результатов поиска.
  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    int timeoutMs = 10000,
    int idleTimeoutMs = 2500,
    int responseLimit = 100,
    int fileLimit = 200,
    SoulseekSearchFilters filters = SoulseekSearchFilters.empty,
  }) async {
    _requireAndroid();
    final q = query.trim();
    if (q.isEmpty) return const [];

    final result = await _invoke<List>('search', {
      'requestId': requestId,
      'query': q,
      'timeoutMs': timeoutMs,
      'idleTimeoutMs': idleTimeoutMs,
      'responseLimit': responseLimit,
      'fileLimit': fileLimit,
      'filters': filters.toMap(),
    });
    if (result == null) return const [];

    return result
        .map((m) => SoulseekSearchResult.fromMap((m as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Downloads / Transfers
  // ═══════════════════════════════════════════════════════════════════

  /// Запускает загрузку файла (или возвращает путь к кэшированному).
  ///
  /// Возвращает [SoulseekDownloadResult]:
  /// - `cacheHit == true` → файл уже в кэше, `result` = локальный путь.
  /// - `cacheHit == false` → загрузка запущена, `result` = downloadId.
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
    _requireAndroid();
    final result = await _invoke<Map>('startDownload', {
      'downloadId': downloadId,
      'peerUsername': peerUsername,
      'remoteFilename': remoteFilename,
      'sizeBytes': sizeBytes,
      'cacheKey': cacheKey,
      'fileExtension': fileExtension,
      'title': ?title,
      'artist': ?artist,
      'durationSeconds': ?durationSeconds,
    });
    if (result == null) {
      throw const SoulseekException('EMPTY_RESPONSE', 'startDownload returned null');
    }
    return SoulseekDownloadResult.fromMap(result.cast<String, dynamic>());
  }

  /// Ставит загрузку на паузу (.part файл сохраняется для resume).
  Future<bool> pauseDownload(String downloadId) async {
    _requireAndroid();
    final result = await _invoke<bool>('pauseDownload', {
      'downloadId': downloadId,
    });
    return result ?? false;
  }

  /// Возобновляет приостановленную загрузку (с checkpoint offset).
  Future<bool> resumeDownload(String downloadId) async {
    _requireAndroid();
    final result = await _invoke<bool>('resumeDownload', {
      'downloadId': downloadId,
    });
    return result ?? false;
  }

  /// Отменяет загрузку и удаляет .part файл.
  Future<bool> cancelDownload(String downloadId) async {
    _requireAndroid();
    final result = await _invoke<bool>('cancelDownload', {
      'downloadId': downloadId,
    });
    return result ?? false;
  }

  /// Возвращает информацию о трансфере по downloadId (или null).
  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async {
    _requireAndroid();
    final result = await _invoke<Map>('getTransfer', {
      'downloadId': downloadId,
    });
    if (result == null) return null;
    return SoulseekTransferInfo.fromMap(result.cast<String, dynamic>());
  }

  /// Возвращает список активных трансферов.
  ///
  /// [includeTerminal] — включать терминальные (completed/failed/cancelled).
  Future<List<SoulseekTransferInfo>> getActiveTransfers({
    bool includeTerminal = false,
  }) async {
    _requireAndroid();
    final result = await _invoke<List>('getActiveTransfers', {
      'includeTerminal': includeTerminal,
    });
    if (result == null) return const [];

    return result
        .map((m) => SoulseekTransferInfo.fromMap((m as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Cache management
  // ═══════════════════════════════════════════════════════════════════

  /// Возвращает запись о кэшированном файле (или null, если файла нет).
  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async {
    _requireAndroid();
    final result = await _invoke<Map>('getCacheEntry', {
      'cacheKey': cacheKey,
    });
    if (result == null) return null;
    return SoulseekCacheEntry.fromMap(result.cast<String, dynamic>());
  }

  /// P1-каскад: полный список завершённых кэш-записей из нативной БД
  /// (LRU-порядок, только файлы, существующие на диске).
  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async {
    _requireAndroid();
    final result = await _invoke<List>('getCacheEntries', null);
    if (result == null) return const [];
    return result
        .map((m) => SoulseekCacheEntry.fromMap((m as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// Удаляет кэш-файл и запись в БД для [cacheKey].
  /// Возвращает true, если что-то было удалено.
  Future<bool> removeCache(String cacheKey) async {
    _requireAndroid();
    final result = await _invoke<bool>('removeCache', {
      'cacheKey': cacheKey,
    });
    return result ?? false;
  }

  /// Закрепляет / открепляет кэш-файл (защита от LRU eviction).
  Future<bool> pinCache(String cacheKey, {required bool pinned}) async {
    _requireAndroid();
    final result = await _invoke<bool>('pinCache', {
      'cacheKey': cacheKey,
      'pinned': pinned,
    });
    return result ?? false;
  }

  /// LRU eviction: удаляет самые старые незакреплённые файлы, пока не уложимся
  /// в лимит. Возвращает количество удалённых файлов.
  Future<int> cleanupCache() async {
    _requireAndroid();
    final result = await _invoke<int>('cleanupCache', null);
    return result ?? 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Sharing configuration
  // ═══════════════════════════════════════════════════════════════════

  /// Настраивает параметры расшаривания (listener, порты, лимиты скорости).
  Future<bool> setSharingDirectory({
    bool? enableListener,
    int? listenPort,
    int? maximumUploadSpeed,
    int? maximumDownloadSpeed,
  }) async {
    _requireAndroid();
    final args = <String, dynamic>{};
    if (enableListener != null) args['enableListener'] = enableListener;
    if (listenPort != null) args['listenPort'] = listenPort;
    if (maximumUploadSpeed != null) {
      args['maximumUploadSpeed'] = maximumUploadSpeed;
    }
    if (maximumDownloadSpeed != null) {
      args['maximumDownloadSpeed'] = maximumDownloadSpeed;
    }
    final result = await _invoke<bool>('setSharingDirectory', args);
    return result ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Внутренний helper — invoke с обработкой PlatformException
  // ═══════════════════════════════════════════════════════════════════

  /// Вызывает MethodChannel и преобразует PlatformException в SoulseekException.
  Future<T?> _invoke<T>(String method, Map<String, dynamic>? arguments) async {
    try {
      return await _method.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      final details = e.details;
      bool retryable = false;
      if (details is Map) {
        retryable = details['retryable'] == true;
      }
      throw SoulseekException(
        e.code,
        e.message ?? 'Unknown platform error',
        retryable: retryable,
      );
    }
  }
}
