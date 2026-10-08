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
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/database/app_database.dart';
import '../models/track.dart';
import 'artwork_provider.dart';
import 'offline_audio_source.dart' as offline;
import 'soulseek_models.dart';
import 'soulseek_platform_channel.dart';
import 'soulseek_stream_audio_source.dart';
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
  ///
  /// [timeoutMs] — жёсткий общий бюджет; [idleTimeoutMs] — «окно тишины»
  /// после первого ответа; [responseLimit]/[fileLimit] — досрочное завершение.
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int idleTimeoutMs,
    required int responseLimit,
    required int fileLimit,
    required SoulseekSearchFilters filters,
  });

  /// Потоковые результаты идущих поисков (дельты по requestId). Итоговый
  /// полный список по-прежнему возвращает [search].
  Stream<SoulseekSearchProgressEvent> get searchProgress;

  /// Отменяет идущий поиск [requestId]; [search] вернёт накопленное.
  Future<void> cancelSearch(String requestId);

  /// Полное содержимое папки [directory] пира [username] (только аудио).
  Future<List<SoulseekSearchResult>> getDirectoryContents({
    required String username,
    required String directory,
    int timeoutMs,
  });

  /// Возвращает запись о кэшированном файле (или null, если файла нет).
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey);

  /// Возвращает все завершённые записи нативного кэша (LRU-порядок).
  ///
  /// P1-каскад: источник истины для кэш-листа — нативная БД, а не
  /// Dart-индекс [_knownCacheKeys], который пополнялся только из
  /// transfer-событий и терял записи, завершённые без активной подписки.
  Future<List<SoulseekCacheEntry>> getCacheEntries();

  /// Запускает загрузку файла (или возвращает путь к кэшированному).
  ///
  /// NEW-3: [title]/[artist]/[durationSeconds] — человекочитаемые
  /// метаданные для кэш-листа (сохраняются в cache_entries при завершении).
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
  });

  /// Возвращает информацию о трансфере по downloadId (или null).
  Future<SoulseekTransferInfo?> getTransfer(String downloadId);

  /// Поток transfer-событий (прогресс / смена состояния / завершение).
  Stream<SoulseekTransferEvent> get transferEvents;
}

class SoulseekSource implements TrackSource, ProgressiveSearchSource {
  static const String sourceId = 'soulseek';

  final SoulseekChannel _channel;

  /// Настраиваемые фильтры поиска (UI Фазы 4 может менять перед вызовом search).
  SoulseekSearchFilters searchFilters = SoulseekSearchFilters.empty;

  /// Интервал поллинга нативного состояния в [_waitForDownloadComplete].
  ///
  /// P1-фикс: события EventChannel могут теряться (переподписка после
  /// onCancel/onListen, рестарт engine) — поллинг getTransfer/getCacheEntry
  /// гарантирует завершение ожидания даже без события.
  @visibleForTesting
  Duration pollInterval = const Duration(seconds: 3);

  /// Общий таймаут ожидания завершения одной загрузки.
  @visibleForTesting
  Duration downloadTimeout = const Duration(minutes: 10);

  /// Стриминг: играть трек во время загрузки, читая `.part`. Выключение
  /// возвращает прежнее поведение (воспроизведение после полной загрузки).
  bool streamingEnabled = true;

  /// Сколько байт `.part` дождаться перед отдачей AudioSource плееру:
  /// подтверждение, что пир реально начал отдавать файл.
  @visibleForTesting
  int streamStartBytes = 256 * 1024;

  /// Интервал проверки роста `.part` при ожидании старта стриминга.
  @visibleForTesting
  Duration streamPollInterval = const Duration(milliseconds: 250);

  /// Таймаут ожидания завершения загрузки, которая уже играет: длинный FLAC
  /// от медленного пира может качаться дольше [downloadTimeout].
  @visibleForTesting
  Duration streamDownloadTimeout = const Duration(hours: 1);

  /// Поиск трека в офлайн-кэше YoutubeCache (DI для тестов).
  @visibleForTesting
  Future<AudioSource?> Function(Track track) offlineAudioSourceLookup =
      offline.createOfflineAudioSource;

  /// NEW-2: таймаут поиска из настроек (soulseek_search_timeout_sec, БД).
  /// Это жёсткий общий бюджет: C# bridge останавливает поиск по его
  /// истечении и возвращает накопленное. Обычно поиск завершается раньше —
  /// по [searchIdleTimeoutMs] или [searchFileLimit]. Загружается лениво из
  /// SQLite при первом поиске; настройка применяется со следующего поиска
  /// после смены. Читается SearchController для внешнего таймаута.
  int searchTimeoutMs = 10000;

  /// «Окно тишины»: после первого ответа поиск завершается, если новых
  /// ответов нет дольше этого окна. Раньше таймер библиотеки сбрасывался на
  /// каждый ответ без общего предела, и популярные запросы шли 25–30 c.
  static const int searchIdleTimeoutMs = 2500;

  /// Досрочное завершение по числу ответов пиров (как в SeekerAndroid).
  static const int searchResponseLimit = 250;

  /// Досрочное завершение по числу аудиофайлов (после фильтров). Ответ пира
  /// по запросу «исполнитель альбом» — это вся папка (10–20 файлов), так что
  /// прежние 200 файлов останавливали поиск на 10–20 пирах.
  static const int searchFileLimit = 2000;

  /// Размер выдачи по умолчанию. Общий дефолт [TrackSource.search] (20)
  /// рассчитан на стриминговые источники; P2P-выдача ценна именно широтой.
  static const int searchResultLimit = 100;

  static const _searchTimeoutKey = 'soulseek_search_timeout_sec';
  bool _searchTimeoutLoaded = false;

  Future<void> _ensureSearchTimeoutLoaded() async {
    if (_searchTimeoutLoaded) return;
    _searchTimeoutLoaded = true;
    try {
      final raw =
          await AppDatabase.instance.getSetting(_searchTimeoutKey);
      final sec = raw == null ? null : int.tryParse(raw);
      if (sec != null && sec > 0) searchTimeoutMs = sec * 1000;
    } catch (_) {
      // best-effort: остаётся дефолт 10 c.
    }
  }

  /// Применяет таймаут поиска из настроек (секунды → миллисекунды).
  ///
  /// Вызывается SoulseekSettingsRepository.applyToSource на старте
  /// приложения и со страницы настроек; сбрасывает ленивую загрузку,
  /// чтобы следующее использование взяло новое значение.
  void applySearchTimeoutSec(int sec) {
    if (sec <= 0) return;
    searchTimeoutMs = sec * 1000;
    _searchTimeoutLoaded = true;
  }

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

  /// Тестовый доступ к [_recordCacheKey].
  @visibleForTesting
  Future<void> recordCacheKeyForTest(String cacheKey) =>
      _recordCacheKey(cacheKey);

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

  /// Поток transfer-событий нативного канала — для подписки UI
  /// (PLAYER-DL-01: статус загрузки на тайле Download в плеере).
  ///
  /// Тонкая точка интеграции: source-aware UI-код подписывается через
  /// `SourceRegistry.instance.get('soulseek') as SoulseekSource`, не
  /// трогая платформенный канал напрямую (в тестах канал подменяется
  /// через конструктор).
  Stream<SoulseekTransferEvent> get transferEvents => _channel.transferEvents;

  /// Возвращает cacheKey трека, если он определим: `extra.cacheKey` или
  /// пересчёт из триады peerUsername/remoteFilename/sizeBytes.
  ///
  /// PLAYER-DL-01: UI (тайл Download) отличает «Soulseek-трек с известным
  /// cacheKey» от «данных недостаточно» (null → fallback на YoutubeCache).
  String? cacheKeyFor(Track track) {
    final existing = track.extra['cacheKey'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;

    final peerUsername = track.extra['peerUsername'] as String?;
    final remoteFilename = track.extra['remoteFilename'] as String?;
    final sizeBytes = _asInt(track.extra['sizeBytes']);

    if (peerUsername == null || remoteFilename == null || sizeBytes <= 0) {
      return null;
    }
    return computeCacheKey(peerUsername, remoteFilename, sizeBytes);
  }

  /// Запись нативного кэша по [cacheKey] (PLAYER-DL-01: проверка статуса
  /// «уже в кэше» тайлом Download). null — файла нет.
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) =>
      _channel.getCacheEntry(cacheKey);

  /// Информация о трансфере по [downloadId] (PLAYER-DL-01: снимок состояния
  /// загрузки при открытии sheet'а — покрывает «лист открыли во время
  /// загрузки»). null — трансфер неизвестен.
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) =>
      _channel.getTransfer(downloadId);

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

  /// Синхронизирует индекс [_knownCacheKeys] с нативным списком кэша.
  ///
  /// P1-каскад: загрузки, завершённые без активной подписки на
  /// transferEvents, не попадали в Dart-индекс — кэш-лист их не показывал.
  /// Вызывается кэш-листом при каждом открытии/обновлении.
  Future<void> refreshCacheIndex() async {
    try {
      final entries = await _channel.getCacheEntries();
      var changed = false;
      for (final e in entries) {
        if (e.complete && _knownCacheKeys.add(e.cacheKey)) changed = true;
      }
      if (changed) await _persistCacheIndex();
    } catch (_) {
      // Не Android / канал недоступен — индекс остаётся как есть.
    }
  }

  @override
  String get id => sourceId;

  @override
  String get displayName => 'Soulseek';

  // ═══════════════════════════════════════════════════════════════════
  //  search
  // ═══════════════════════════════════════════════════════════════════

  /// Сколько живёт завершённая выдача в [_searchCache]. Повторный поиск того
  /// же запроса (смена чипа «Все» → «Soulseek», запрос из истории) берёт её
  /// мгновенно вместо нового P2P-поиска на секунды.
  static const Duration searchCacheTtl = Duration(minutes: 10);
  static const int _searchCacheMaxEntries = 20;

  /// Завершённые выдачи по ключу [_searchKey].
  final Map<String, ({DateTime at, List<Track> tracks})> _searchCache = {};

  /// Идущие поиски по ключу [_searchKey] — повторный подписчик
  /// присоединяется к ним, а не запускает второй P2P-поиск.
  final Map<String, _SearchRun> _searchRuns = {};

  String _searchKey(String q, int limit) =>
      '$q\u0000$limit\u0000${jsonEncode(searchFilters.toMap())}';

  /// Сбрасывает кэш выдачи (например, после смены фильтров в настройках).
  void clearSearchCache() => _searchCache.clear();

  @override
  Future<List<Track>> search(String query, {int limit = searchResultLimit}) =>
      searchProgressive(query, limit: limit)
          .fold(const <Track>[], (_, snapshot) => snapshot);

  @override
  Stream<List<Track>> searchProgressive(
    String query, {
    int limit = searchResultLimit,
  }) {
    // На не-Android платформах Soulseek недоступен — пустая выдача,
    // чтобы SourceRegistry.searchable не падал.
    final q = query.trim();
    if (!_channel.isAvailable || q.isEmpty) {
      return Stream.value(const <Track>[]);
    }

    final key = _searchKey(q, limit);
    final cached = _searchCache[key];
    if (cached != null) {
      if (DateTime.now().difference(cached.at) < searchCacheTtl) {
        return Stream.value(cached.tracks);
      }
      _searchCache.remove(key);
    }

    // Присоединение к идущему поиску выполняется синхронно — до таймера
    // отмены, который мог запланировать предыдущий подписчик.
    final run = _searchRuns[key] ?? _startSearchRun(key, q, limit);
    late final StreamController<List<Track>> controller;
    controller = StreamController<List<Track>>(
      onListen: () => run.attach(controller),
      onCancel: () {
        run.detach(controller);
        if (run.listeners.isNotEmpty || run.finished) return;
        // Отменяем натив на следующем тике: SearchController при смене
        // фильтра сначала отписывается от старого поиска и тут же
        // подписывается на тот же запрос — такой поиск должен продолжиться.
        Timer(Duration.zero, () {
          if (run.listeners.isNotEmpty || run.finished) return;
          run.cancelled = true;
          if (_searchRuns[key] == run) _searchRuns.remove(key);
          unawaited(_channel.cancelSearch(run.requestId));
        });
      },
    );
    return controller.stream;
  }

  _SearchRun _startSearchRun(String key, String q, int limit) {
    final run = _SearchRun(const Uuid().v4());
    _searchRuns[key] = run;
    unawaited(_executeSearchRun(run, key, q, limit));
    return run;
  }

  Future<void> _executeSearchRun(
    _SearchRun run,
    String key,
    String q,
    int limit,
  ) async {
    final acc = _SearchAccumulator(
      filters: searchFilters,
      limit: limit,
      identity: identityKey,
      toTrack: _resultToTrack,
    );
    StreamSubscription<SoulseekSearchProgressEvent>? progressSub;
    var failed = false;
    try {
      // NEW-2: применяем настраиваемый таймаут из настроек (default 10 c).
      await _ensureSearchTimeoutLoaded();
      // Отписались, пока читали настройку: нативный поиск ещё не запущен,
      // и cancelSearch его не нашёл бы — просто не запускаем.
      if (run.cancelled) {
        run.finish(const []);
        return;
      }

      // Подписка до запуска поиска — иначе первые дельты потерялись бы.
      progressSub = _channel.searchProgress
          .where((e) => e.requestId == run.requestId)
          .listen((e) {
        if (acc.addBatch(e.results)) run.publish(acc.snapshot());
      });

      final results = await _channel.search(
        requestId: run.requestId,
        query: q,
        timeoutMs: searchTimeoutMs,
        idleTimeoutMs: searchIdleTimeoutMs,
        responseLimit: searchResponseLimit,
        fileLimit: searchFileLimit,
        filters: searchFilters,
      );
      // Итоговый список — надмножество дельт: уже учтённое отсеет дедуп.
      acc.addBatch(results);

      if (kDebugMode) {
        debugPrint('[Soulseek] search "$q": ${results.length} raw, '
            '${acc.snapshot().length} tracks after dedup+group+limit');
      }
    } on SoulseekException catch (e) {
      failed = true;
      if (kDebugMode) debugPrint('[Soulseek] search failed: $e');
    } on UnsupportedError {
      failed = true;
    } finally {
      await progressSub?.cancel();
      if (_searchRuns[key] == run) _searchRuns.remove(key);
    }

    final tracks = acc.snapshot();
    // В кэш — только полный ответ: отменённый поиск или ошибка (нет
    // соединения) не должны на 10 минут подменять настоящую выдачу.
    if (!run.cancelled && !failed) {
      _searchCache
        ..remove(key)
        ..[key] = (at: DateTime.now(), tracks: tracks);
      while (_searchCache.length > _searchCacheMaxEntries) {
        _searchCache.remove(_searchCache.keys.first);
      }
    }
    run.finish(tracks);
  }

  /// Ранжирует результаты по тому, как быстро пир отдаст файл: сначала
  /// пиры со свободным слотом, затем с более короткой очередью, затем с
  /// большей скоростью. При равенстве сохраняется порядок прихода ответов
  /// (первыми отвечают самые отзывчивые пиры).
  @visibleForTesting
  static List<SoulseekSearchResult> rankResults(
    List<SoulseekSearchResult> results,
  ) {
    final indexed = [for (var i = 0; i < results.length; i++) (i, results[i])];
    indexed.sort((a, b) {
      final ra = a.$2, rb = b.$2;
      final slot = (rb.freeUploadSlots > 0 ? 1 : 0)
          .compareTo(ra.freeUploadSlots > 0 ? 1 : 0);
      if (slot != 0) return slot;
      final queue = ra.queueLength.compareTo(rb.queueLength);
      if (queue != 0) return queue;
      final speed = rb.uploadSpeed.compareTo(ra.uploadSpeed);
      if (speed != 0) return speed;
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Маппинг [SoulseekSearchResult] → [Track].
  ///
  /// [peerCount] — сколько полностью одинаковых файлов свёрнуто в этот трек
  /// (`extra.peerCount`, бейдж «×N» в выдаче).
  ///
  /// [folderKey] — трек входит в папку-альбом выдачи (`extra.folderKey`,
  /// UI сворачивает такие треки в карточку); [folderPeers] — у скольких
  /// пиров есть такая же папка (`extra.folderPeers`).
  Track _resultToTrack(
    SoulseekSearchResult result,
    int peerCount, {
    String? folderKey,
    int folderPeers = 1,
  }) {
    final cacheKey =
        computeCacheKey(result.username, result.filename, result.sizeBytes);

    return Track(
      // HISTORY-DUP-01: стабильный id = cacheKey (детерминирован по
      // peer+filename+size). resultId (UUID поиска) меняется от поиска к
      // поиску, из-за чего один файл из кэш-шторки (id=cacheKey) и из
      // поиска (id=resultId) давал разные globalId → дубликаты в истории
      // и «засорение» плейлистов. С единым id трек дедуплицируется везде.
      id: cacheKey,
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
        if (peerCount > 1) 'peerCount': peerCount,
        'folderKey': ?folderKey,
        if (folderKey != null && folderPeers > 1) 'folderPeers': folderPeers,
      },
    );
  }

  /// Загруженные папки по [folderKeyOf] — повторное открытие без запроса.
  final Map<String, ({DateTime at, List<Track> tracks})> _folderCache = {};

  /// Полное содержимое папки, в которой лежат [known] (треки одного пира и
  /// одного каталога — карточка папки или одиночный трек выдачи).
  ///
  /// Поиск отдаёт только совпавшие с запросом файлы; здесь у пира
  /// запрашивается вся папка (FolderContentsRequest), как «Get folder
  /// contents» в SeekerAndroid. Уже известные треки возвращаются как есть
  /// (с длительностью, качеством и обложкой: в ответе папки атрибутов часто
  /// нет), новые получают статистику пира и обложку от известных. Порядок —
  /// по полному пути (подпапки CD1/CD2 идут подряд). Ошибки канала
  /// пробрасываются: UI оставляет [known].
  Future<List<Track>> loadFolder(List<Track> known) async {
    if (known.isEmpty) return known;
    final first = known.first;
    final username = first.extra['peerUsername'] as String?;
    final remote = first.extra['remoteFilename'] as String?;
    if (username == null || remote == null) return known;
    final directory = folderOf(remote);
    if (directory.isEmpty) return known;
    final key = folderKeyOf(username, remote);

    final cached = _folderCache[key];
    if (cached != null && DateTime.now().difference(cached.at) < searchCacheTtl) {
      return cached.tracks;
    }

    final files = await _channel.getDirectoryContents(
      username: username,
      directory: directory,
    );
    if (files.isEmpty) return known;

    final byFile = {
      for (final t in known) t.extra['remoteFilename'] as String?: t,
    };
    final artwork = known
        .map((t) => t.artworkUrl)
        .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
    final hasFreeSlot = first.extra['hasFreeUploadSlot'] == true;
    final queueLength = _asInt(first.extra['queueLength']);
    final uploadSpeed = _asInt(first.extra['uploadSpeed']);

    final sorted = [...files]
      ..sort((a, b) =>
          a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
    final tracks = <Track>[
      for (final r in sorted)
        byFile[r.filename] ??
            _resultToTrack(
              SoulseekSearchResult(
                resultId: r.resultId,
                username: username,
                filename: r.filename,
                sizeBytes: r.sizeBytes,
                extension: r.extension,
                bitrate: r.bitrate,
                sampleRate: r.sampleRate,
                bitDepth: r.bitDepth,
                durationSeconds: r.durationSeconds,
                queueLength: queueLength,
                freeUploadSlots: hasFreeSlot ? 1 : 0,
                uploadSpeed: uploadSpeed,
              ),
              1,
              folderKey: key,
            ).copyWith(artworkUrl: artwork),
    ];
    // Совпавшие в поиске файлы не теряем, даже если пир их не перечислил.
    final listed = {for (final r in files) r.filename};
    tracks.addAll(
        known.where((t) => !listed.contains(t.extra['remoteFilename'])));

    _folderCache
      ..remove(key)
      ..[key] = (at: DateTime.now(), tracks: tracks);
    while (_folderCache.length > _searchCacheMaxEntries) {
      _folderCache.remove(_folderCache.keys.first);
    }
    return tracks;
  }

  /// Каталог файла на стороне пира: всё до последнего разделителя
  /// (Windows-пиры шлют `\`, остальные — `/`). Пусто — файл в корне.
  static String folderOf(String filename) {
    final i = filename.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? '' : filename.substring(0, i);
  }

  /// Имя файла без каталога (с расширением).
  static String leafOf(String filename) {
    final i = filename.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? filename : filename.substring(i + 1);
  }

  /// Ключ папки пира: файлы с одинаковым ключом — одна папка-альбом.
  static String folderKeyOf(String username, String filename) =>
      '$username|${folderOf(filename)}';

  /// Строит [Track] из записи нативного кэша [SoulseekCacheEntry].
  ///
  /// CACHE-UI-01 (данные, без UI): ключевой момент — `extra.cacheKey`:
  /// [`_getOrCreateCacheKey`] возвращает его без требования триады
  /// peerUsername/remoteFilename/sizeBytes, а `resolveStreamUrl` первым
  /// шагом делает `getCacheEntry(cacheKey)` → мгновенный cache hit по
  /// `localPath` без повторной загрузки.
  ///
  /// Метка качества: из `extension` записи («FLAC»/«MP3») или из
  /// `localPath` (fallback для старых записей без колонки extension);
  /// точный битрейт кэш-запись не хранит — детали возьмут его из extra
  /// трека, если он известен (например, трек добавлен из поиска).
  Track trackFromCacheEntry(SoulseekCacheEntry entry) {
    final extension =
        (entry.extension ?? _extensionFromPath(entry.localPath)) ?? '';
    final label = extension.isNotEmpty ? qualityLabel(extension, null, null, null) : null;

    return Track(
      // cacheKey — детерминированный идентификатор файла в нативном кэше.
      id: entry.cacheKey,
      sourceId: sourceId,
      title: (entry.title != null && entry.title!.isNotEmpty)
          ? entry.title!
          : basenameWithoutExt(entry.localPath),
      artist: (entry.artist != null && entry.artist!.isNotEmpty)
          ? entry.artist!
          : 'Unknown',
      duration: entry.durationSeconds != null
          ? Duration(seconds: entry.durationSeconds!)
          : null,
      qualityLabel: label,
      extra: <String, dynamic>{
        'cacheKey': entry.cacheKey,
        if (extension.isNotEmpty) 'extension': extension,
      },
    );
  }

  /// Извлекает расширение из локального пути (последняя точка в basename).
  String? _extensionFromPath(String path) {
    final basename = path.replaceAll('\\', '/').split('/').last;
    final dot = basename.lastIndexOf('.');
    if (dot <= 0 || dot == basename.length - 1) return null;
    return basename.substring(dot + 1).toLowerCase();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  resolveStreamUrl — обеспечение локального файла
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final cacheKey = _getOrCreateCacheKey(track);

    // 1. Проверка кэша: файл уже скачан и complete?
    final cachedPath = await _completeCachePath(cacheKey);
    if (cachedPath != null) return cachedPath;

    // 2. Запуск загрузки (или присоединение к идущей).
    final result = await _startDownload(track, cacheKey);

    // Cache hit — файл уже complete (мог появиться между шагами 1 и 2).
    if (result.cacheHit) return result.result;

    // 3. Ждём завершения загрузки через event stream.
    //    result.result — downloadId (может отличаться при dedupe).
    return _waitForDownloadComplete(result.result);
  }

  /// Путь полностью скачанного файла из нативного кэша или null.
  Future<String?> _completeCachePath(String cacheKey) async {
    final entry = await _channel.getCacheEntry(cacheKey);
    if (entry == null || !entry.complete) return null;
    if (kDebugMode) debugPrint('[Soulseek] cache hit: $cacheKey → ${entry.localPath}');
    return entry.localPath;
  }

  /// Запускает загрузку трека (или присоединяется к идущей).
  Future<SoulseekDownloadResult> _startDownload(
    Track track,
    String cacheKey,
  ) async {
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
      // NEW-3: человекочитаемые метаданные для кэш-листа.
      title: track.title,
      artist: track.artist,
      durationSeconds: track.duration?.inSeconds,
    );

    if (result.cacheHit && kDebugMode) {
      debugPrint('[Soulseek] startDownload cache hit: ${result.result}');
    }
    return result;
  }

  /// Ждёт завершения загрузки [downloadId] — событие ИЛИ поллинг-fallback.
  ///
  /// P1-фикс: раньше ожидание опиралось только на transfer-события
  /// EventChannel. Если событие терялось (переподписка onCancel→onListen,
  /// рестарт engine), completer не завершался никогда. Теперь:
  ///  1. Подписка на события (основной путь).
  ///  2. Немедленная проверка текущего состояния после подписки.
  ///  3. Поллинг getTransfer + getCacheEntry(cacheKey) каждые [pollInterval]
  ///     — гарантированное завершение даже без событий.
  ///  4. Общий таймаут [timeout] (по умолчанию [downloadTimeout]) — бросает
  ///     SoulseekException.
  ///
  /// [abandon] — досрочный отказ от ожидания (стриминг не дождался старта):
  /// останавливает поллинг, сама загрузка продолжается нативно.
  Future<String> _waitForDownloadComplete(
    String downloadId, {
    Duration? timeout,
    Future<void>? abandon,
  }) async {
    final cacheKey = downloadId.replaceFirst('dl_', '');
    final completer = Completer<String>();
    abandon?.then<void>((_) {
      if (!completer.isCompleted) {
        completer.completeError(const SoulseekException(
          'DOWNLOAD_ABANDONED',
          'Stopped waiting for download',
        ));
      }
    });
    Timer? pollTimer;

    void finish() {
      pollTimer?.cancel();
    }

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
    final cacheKeyForIndex = cacheKey;

    // Однократная проверка нативного состояния (race-safe: событие могло
    // прийти между startDownload и подпиской).
    Future<void> probeOnce() async {
      // 1. Состояние трансфера.
      try {
        final current = await _channel.getTransfer(downloadId);
        if (current != null) {
          handleInfo(current);
          if (current.state == SoulseekTransferState.completed) {
            _recordCacheKey(cacheKeyForIndex);
          }
          if (completer.isCompleted) return;
        }
      } catch (_) {
        // Игнорируем — основной путь события/поллинга продолжит работу.
      }
      if (completer.isCompleted) return;

      // 2. Файл мог появиться в кэше даже без трансфера в мапе
      //    (например, завершён другим процессом или после рестарта сервиса).
      try {
        final entry = await _channel.getCacheEntry(cacheKey);
        if (entry != null && entry.complete) {
          if (!completer.isCompleted) completer.complete(entry.localPath);
          _recordCacheKey(cacheKeyForIndex);
        }
      } catch (_) {
        // Игнорируем.
      }
    }

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

    // Поллинг-fallback: периодическая probeOnce до терминального состояния.
    pollTimer = Timer.periodic(pollInterval, (_) => probeOnce());

    // Немедленная первая проверка после подписки.
    await probeOnce();

    try {
      return await completer.future.timeout(
        timeout ?? downloadTimeout,
        onTimeout: () => throw const SoulseekException(
          'DOWNLOAD_TIMEOUT',
          'Download timed out',
          retryable: true,
        ),
      );
    } finally {
      finish();
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
    final offlineSource = await offlineAudioSourceLookup(track);
    if (offlineSource != null) return offlineSource;

    // 2. Без стриминга — дождаться полного файла (кэш Soulseek → скачать).
    if (!streamingEnabled) {
      return AudioSource.uri(Uri.file(await resolveStreamUrl(track)));
    }

    // 3. Стриминг: готовый файл из кэша или чтение .part во время загрузки.
    final cacheKey = _getOrCreateCacheKey(track);
    final cachedPath = await _completeCachePath(cacheKey);
    if (cachedPath != null) return AudioSource.uri(Uri.file(cachedPath));

    final result = await _startDownload(track, cacheKey);
    if (result.cacheHit) return AudioSource.uri(Uri.file(result.result));

    final partPath = result.partPath;
    if (partPath == null) {
      // Нативная сторона не сообщила путь .part (старый контракт канала).
      final path = await _waitForDownloadComplete(result.result);
      return AudioSource.uri(Uri.file(path));
    }
    return _createStreamSource(track, result.result, partPath);
  }

  /// Стриминг: ждёт [streamStartBytes] новых байт в `.part` и отдаёт
  /// [SoulseekStreamAudioSource], который дочитывает файл по мере загрузки.
  ///
  /// Ожидание старта ограничено [downloadTimeout] — очередь у пира или
  /// оффлайн-пир дают ошибку до setAudioSource, как и без стриминга.
  /// Если загрузка завершилась раньше порога, играем готовый файл.
  Future<AudioSource> _createStreamSource(
    Track track,
    String downloadId,
    String partPath,
  ) async {
    final sizeBytes = _asInt(track.extra['sizeBytes']);
    final extension = (track.extra['extension'] as String?) ?? 'dat';

    final abandon = Completer<void>();
    // Ожидание завершения живёт всё время воспроизведения: индексирует
    // кэш и сообщает читателю об успехе/ошибке загрузки.
    final completion = _waitForDownloadComplete(
      downloadId,
      timeout: streamDownloadTimeout,
      abandon: abandon.future,
    );
    String? completedPath;
    Object? failure;
    unawaited(completion.then<void>(
      (path) => completedPath = path,
      onError: (Object e) => failure = e,
    ));

    // Порог — прирост относительно начального размера: остаток прошлой
    // попытки уже может быть больше порога, а пир (в очереди/оффлайн) ещё
    // ничего не отдал. Ждём подтверждения, что загрузка реально идёт.
    final initialBytes = await _fileLength(partPath);
    final threshold = math.min(initialBytes + streamStartBytes, sizeBytes);
    final sw = Stopwatch()..start();
    while (true) {
      final error = failure;
      if (error != null) throw error;
      final path = completedPath;
      if (path != null) return AudioSource.uri(Uri.file(path));

      final written = await _fileLength(partPath);
      if (written >= threshold) break;

      if (sw.elapsed >= downloadTimeout) {
        if (!abandon.isCompleted) abandon.complete();
        throw const SoulseekException(
          'DOWNLOAD_TIMEOUT',
          'Download did not start in time',
          retryable: true,
        );
      }
      await Future<void>.delayed(streamPollInterval);
    }

    if (kDebugMode) {
      debugPrint('[Soulseek] streaming $downloadId from .part '
          'after ${sw.elapsedMilliseconds} ms');
    }
    return SoulseekStreamAudioSource(
      partPath: partPath,
      totalBytes: sizeBytes,
      contentType: SoulseekStreamAudioSource.contentTypeFor(extension),
      completion: completion,
    );
  }

  static Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return 0;
    }
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

  /// Soulseek не предоставляет обложек в поисковой выдаче — используем
  /// общий ArtworkProvider (Genius/iTunes) как фолбэк по artist/title.
  /// FLAC PICTURE / ID3 APIC извлечение из файла отложено (опционально).
  @override
  Future<String?> resolveArtwork(Track track) async {
    try {
      return await ArtworkProvider.instance
          .findArtwork(track.artist, track.title);
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  P5: фоновое обогащение обложками (паттерн MuzmoSource)
  // ═══════════════════════════════════════════════════════════════════

  /// Запускает фоновое дозаполнение artworkUrl через ArtworkProvider
  /// (Genius/iTunes) по artist/title — не блокируя выдачу результатов
  /// поиска (P5: [_resultToTrack] ставит artworkUrl = null).
  ///
  /// Паттерн MuzmoSource/SoundCloudSource: приоритет видимых треков,
  /// ограничение параллелизма, батч-обновление UI через [onUpdate].
  void enrichArtworksInBackground(
    List<Track> tracks,
    void Function(List<Track> updated) onUpdate,
  ) {
    final mutable = List<Track>.of(tracks);
    unawaited(_enrichArtworks(mutable, onUpdate));
  }

  /// Приоритетный индекс: треки переставляются так, чтобы первые N
  /// (видимая область экрана) обрабатывались раньше остальных.
  static const int _visibleCount = 8;

  List<int> _priorityIndices(int total) {
    final indices = <int>[];
    // Сначала видимые (0 → _visibleCount-1)
    for (var i = 0; i < total && i < _visibleCount; i++) {
      indices.add(i);
    }
    // Затем остальные
    for (var i = _visibleCount; i < total; i++) {
      indices.add(i);
    }
    return indices;
  }

  Future<void> _enrichArtworks(
    List<Track> tracks, [
    void Function(List<Track> updated)? onUpdate,
  ]) async {
    const concurrency = 6;
    // Треки папки-альбома делят одну обложку: ищем по первому треку папки
    // и раздаём её всем — иначе альбом из 15 треков давал 15 запросов.
    final order = <int>[];
    final members = <int, List<int>>{};
    final leadByFolder = <String, int>{};
    for (final idx in _priorityIndices(tracks.length)) {
      final folder = tracks[idx].extra['folderKey'] as String?;
      final lead = folder == null ? null : leadByFolder[folder];
      if (lead != null) {
        members[lead]!.add(idx);
        continue;
      }
      if (folder != null) leadByFolder[folder] = idx;
      order.add(idx);
      members[idx] = [idx];
    }
    var pos = 0;

    void apply(int lead, String url) {
      for (final m in members[lead]!) {
        final art = tracks[m].artworkUrl;
        if (art == null || art.isEmpty) {
          tracks[m] = tracks[m].copyWith(artworkUrl: url);
        }
      }
    }

    Timer? notifyTimer;
    void scheduleNotify() {
      if (onUpdate == null) return;
      notifyTimer?.cancel();
      notifyTimer = Timer(const Duration(milliseconds: 50), () {
        onUpdate(List<Track>.of(tracks));
      });
    }

    Future<void> worker() async {
      while (true) {
        final i = pos++;
        if (i >= order.length) return;
        final idx = order[i];
        final t = tracks[idx];
        // Уже обогащённые пропускаем: enrich получает треки из
        // state.results, где могли остаться обложки прошлого поиска.
        if (t.artworkUrl != null && t.artworkUrl!.isNotEmpty) {
          if (members[idx]!.length > 1) {
            apply(idx, t.artworkUrl!);
            scheduleNotify();
          }
          continue;
        }
        try {
          final url = await ArtworkProvider.instance
              .findArtwork(t.artist, t.title)
              .timeout(const Duration(seconds: 4));
          if (url != null && url.isNotEmpty) {
            apply(idx, url);
            scheduleNotify();
            // Прекэшируем миниатюру (200px — размер для списков),
            // чтобы к моменту перерисовки UI она уже была в кэше.
            unawaited(_precacheThumb(url));
          }
        } on TimeoutException {
          // best-effort
        } catch (_) {
          // best-effort
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    notifyTimer?.cancel();
    if (onUpdate != null) onUpdate(List<Track>.of(tracks));
  }

  /// Фоновый прекэш уменьшенной обложки в CachedNetworkImage,
  /// чтобы UI показал картинку мгновенно, без второго сетевого круга.
  static final Set<String> _precachedUrls = {};

  /// В flutter test нет path_provider — CachedNetworkImageProvider падает
  /// с MissingPluginException (unhandled zone error роняет тест).
  /// Прекэш — чистая оптимизация, тесты его отключают.
  @visibleForTesting
  static bool precacheThumbsEnabled = true;

  static Future<void> _precacheThumb(String url) async {
    if (_precachedUrls.contains(url)) return;
    if (!precacheThumbsEnabled) return;
    _precachedUrls.add(url);
    try {
      final provider = CachedNetworkImageProvider(url);
      final config = ImageConfiguration(size: const Size(200, 200));
      final stream = provider.resolve(config);
      final completer = Completer<void>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          info.image.dispose();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e, stack) {
          if (!completer.isCompleted) completer.complete();
        },
      );
      stream.addListener(listener);
      try {
        await completer.future;
      } finally {
        stream.removeListener(listener);
      }
    } catch (_) {}
  }

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

  /// Ключ «абсолютно одинакового» трека: исполнитель, название,
  /// длительность и все параметры качества (расширение, битрейт, битность,
  /// частота) совпадают точно. null — одинаковость не подтвердить
  /// (неизвестны длительность или исполнитель): такой файл не сворачивается.
  @visibleForTesting
  String? identityKey(SoulseekSearchResult r) {
    final duration = r.durationSeconds;
    if (duration == null || duration <= 0) return null;
    final artist = extractArtist(r.filename);
    if (artist == 'Unknown') return null;
    return [
      artist,
      extractTitle(r.filename),
      duration,
      r.extension,
      r.bitrate,
      r.bitDepth,
      r.sampleRate,
    ].join('\u0000');
  }
}

/// Один P2P-поиск, на который могут быть подписаны несколько потоков
/// [SoulseekSource.searchProgressive] (например, «Все» → чип «Soulseek»).
class _SearchRun {
  _SearchRun(this.requestId);

  final String requestId;
  final Set<StreamController<List<Track>>> listeners = {};
  List<Track> latest = const [];
  bool finished = false;

  /// Отменён, потому что от него отписались все — в кэш не попадает.
  bool cancelled = false;

  void attach(StreamController<List<Track>> c) {
    if (finished) {
      c
        ..add(latest)
        ..close();
      return;
    }
    listeners.add(c);
    if (latest.isNotEmpty) c.add(latest);
  }

  void detach(StreamController<List<Track>> c) => listeners.remove(c);

  void publish(List<Track> snapshot) {
    latest = snapshot;
    for (final c in listeners.toList()) {
      c.add(snapshot);
    }
  }

  void finish(List<Track> tracks) {
    latest = tracks;
    finished = true;
    final current = listeners.toList();
    listeners.clear();
    for (final c in current) {
      c
        ..add(tracks)
        ..close();
    }
  }
}

/// Сворачиваемая группа одинаковых файлов: первый пришедший (лучший в своей
/// пачке) остаётся представителем, остальные лишь увеличивают [count].
class _ResultGroup {
  _ResultGroup(this.representative);

  final SoulseekSearchResult representative;
  int count = 1;
}

/// Элемент выдачи: одиночный трек или папка пира (альбом), как в Seeker.
/// [limit] аккумулятора считает элементы, а не треки.
class _Entry {
  _Entry.single(_ResultGroup group)
      : tracks = [group],
        folderKey = null;

  _Entry.folder(String this.folderKey, this.tracks);

  /// Ключ папки (`username` + каталог); null — одиночный трек.
  final String? folderKey;
  final List<_ResultGroup> tracks;

  /// Сколько пиров прислали ту же папку (те же имена и размеры файлов).
  int folderPeers = 1;
}

/// Инкрементальная сборка выдачи Soulseek из пачек ответов пиров.
///
/// Только дописывает: уже показанные элементы остаются на своих местах,
/// новые встают в конец (внутри пачки — по [SoulseekSource.rankResults]).
///
/// Файлы одного пира из одной папки (2+ шт.) становятся папкой-альбомом:
/// её треки идут подряд и несут `extra.folderKey`, UI сворачивает их в
/// карточку. Такая же папка у другого пира (тот же набор имён и размеров)
/// лишь увеличивает `extra.folderPeers`. Одиночные полностью одинаковые
/// файлы ([SoulseekSource.identityKey]) сворачиваются в один трек с
/// `extra.peerCount`.
class _SearchAccumulator {
  _SearchAccumulator({
    required this.filters,
    required this.limit,
    required this.identity,
    required this.toTrack,
  });

  final SoulseekSearchFilters filters;
  final int limit;
  final String? Function(SoulseekSearchResult) identity;
  final Track Function(
    SoulseekSearchResult,
    int peerCount, {
    String? folderKey,
    int folderPeers,
  }) toTrack;

  final _seenPeerFiles = <String>{};
  final _seenIds = <String>{};
  final _entries = <_Entry>[];
  final _groupByKey = <String, _ResultGroup>{};
  final _groupByFile = <String, _ResultGroup>{};
  final _folderByKey = <String, _Entry>{};
  final _folderBySignature = <String, _Entry>{};

  /// Добавляет пачку результатов; true — выдача изменилась.
  bool addBatch(List<SoulseekSearchResult> batch) {
    final fresh = <SoulseekSearchResult>[];
    for (final r in batch) {
      // Пост-фильтрация на Dart-стороне (дублирование native-фильтров).
      if (!filters.matches(r)) continue;
      // Точные повторы — тот же resultId или тот же файл того же пира
      // (P4-защита: дубликаты resultId давали несколько треков с одинаковым
      // globalId → мульти-подсветка «играющих»). Здесь же отсеивается
      // повтор дельт в итоговом списке поиска.
      final peerFileKey = '${r.username}|${r.filename}|${r.sizeBytes}';
      if (_seenPeerFiles.contains(peerFileKey)) continue;
      if (r.resultId.isNotEmpty && _seenIds.contains(r.resultId)) continue;
      _seenPeerFiles.add(peerFileKey);
      if (r.resultId.isNotEmpty) _seenIds.add(r.resultId);
      fresh.add(r);
    }
    if (fresh.isEmpty) return false;

    // Папки в порядке первого файла в ранжированной пачке.
    final buckets = <String, List<SoulseekSearchResult>>{};
    for (final r in SoulseekSource.rankResults(fresh)) {
      buckets
          .putIfAbsent(SoulseekSource.folderKeyOf(r.username, r.filename),
              () => [])
          .add(r);
    }

    var changed = false;
    for (final MapEntry(key: folderKey, value: files) in buckets.entries) {
      // Дозапись в уже показанную папку (ответ пира пришёл в двух дельтах).
      final known = _folderByKey[folderKey];
      if (known != null) {
        for (final r in _sortedByName(files)) {
          known.tracks.add(_register(r));
        }
        changed = true;
        continue;
      }
      if (files.length >= 2) {
        changed |= _addFolder(folderKey, files);
      } else {
        changed |= _addSingle(files.single);
      }
    }
    return changed;
  }

  bool _addFolder(String folderKey, List<SoulseekSearchResult> files) {
    final sorted = _sortedByName(files);
    final signature = [
      for (final r in sorted)
        '${SoulseekSource.leafOf(r.filename).toLowerCase()}|${r.sizeBytes}',
    ].join('/');
    final same = _folderBySignature[signature];
    if (same != null) {
      same.folderPeers++;
      return true;
    }
    if (_entries.length >= limit) return false;
    final entry = _Entry.folder(folderKey, [for (final r in sorted) _register(r)]);
    _entries.add(entry);
    _folderByKey[folderKey] = entry;
    _folderBySignature[signature] = entry;
    return true;
  }

  bool _addSingle(SoulseekSearchResult r) {
    // Тот же файл (путь + размер) у другого пира — тот же трек, даже если
    // одинаковость по метаданным не подтвердить (нет длительности).
    final fileKey = '${r.filename}|${r.sizeBytes}';
    final key = identity(r);
    final existing =
        _groupByFile[fileKey] ?? (key == null ? null : _groupByKey[key]);
    if (existing != null) {
      existing.count++;
      _groupByFile[fileKey] = existing;
      return true;
    }
    if (_entries.length >= limit) return false;
    _entries.add(_Entry.single(_register(r)));
    return true;
  }

  /// Новая группа для [r]; по ней будут сворачиваться одиночные повторы.
  _ResultGroup _register(SoulseekSearchResult r) {
    final group = _ResultGroup(r);
    _groupByFile.putIfAbsent('${r.filename}|${r.sizeBytes}', () => group);
    final key = identity(r);
    if (key != null) _groupByKey.putIfAbsent(key, () => group);
    return group;
  }

  /// Порядок треков в папке — по имени файла (обычно с номером трека).
  static List<SoulseekSearchResult> _sortedByName(
    List<SoulseekSearchResult> files,
  ) =>
      [...files]..sort((a, b) => SoulseekSource.leafOf(a.filename)
          .toLowerCase()
          .compareTo(SoulseekSource.leafOf(b.filename).toLowerCase()));

  List<Track> snapshot() => [
        for (final e in _entries)
          for (final g in e.tracks)
            toTrack(
              g.representative,
              g.count,
              folderKey: e.folderKey,
              folderPeers: e.folderPeers,
            ),
      ];
}
