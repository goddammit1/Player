import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../sources/artwork_provider.dart';
import '../sources/source_registry.dart';
import 'app_database.dart';
import 'artwork_helper.dart';
import 'playlist_repository.dart';

/// Одна запись истории прослушивания: трек + момент воспроизведения.
class HistoryEntry {
  final Track track;
  final DateTime playedAt;

  const HistoryEntry({required this.track, required this.playedAt});

  Map<String, dynamic> toJson() => {
        'track': track.toMap(),
        'played_at': playedAt.millisecondsSinceEpoch,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> m) => HistoryEntry(
        track: Track.fromMap((m['track'] as Map).cast<String, dynamic>()),
        playedAt:
            DateTime.fromMillisecondsSinceEpoch((m['played_at'] as num).toInt()),
      );

  /// Идентичность записи для удаления из UI.
  bool sameAs(HistoryEntry other) =>
      other.track.globalId == track.globalId &&
      other.playedAt.millisecondsSinceEpoch ==
          playedAt.millisecondsSinceEpoch;
}

/// Persistence + state-store для истории прослушивания.
///
/// Хранилище — SQLite через [AppDatabase]. Паттерн полностью повторяет
/// [PlaylistRepository]: broadcast-стрим для UI + снапшот, запись на
/// диск дебаунсится 300 мс.
///
/// Лимит записей выбирается пользователем (хранится в таблице `settings`
/// под ключом `history_limit_v1`), абсолютный максимум — [maxLimit].
class HistoryRepository {
  HistoryRepository._();
  static final HistoryRepository instance = HistoryRepository._();

  /// Абсолютный максимум записей.
  static const int maxLimit = 200;

  /// Дефолтный лимит, пока пользователь не выбрал свой.
  static const int defaultLimit = 100;

  final StreamController<List<HistoryEntry>> _controller =
      StreamController<List<HistoryEntry>>.broadcast();
  List<HistoryEntry> _list = [];
  int _limit = defaultLimit;
  Future<void>? _initFuture;

  // ---- Фоновое обогащение обложек ----
  // Механика зеркалит PlaylistRepository: кандидаты собираются по TTL
  // провайдерского кэша и применяются батчем, чтобы старт приложения не
  // превращался в сетевой шторм.
  static const int _maxEnrichConcurrency = 3;
  static const int _maxEnrichPerLoad = 50;
  static const Duration _artworkFlushInterval = Duration(milliseconds: 150);

  final _Semaphore _enrichSemaphore = _Semaphore(_maxEnrichConcurrency);
  final Set<Future<void>> _enrichmentInFlight = {};

  /// Хвостовые задачи кросс-пропагации обложек в [PlaylistRepository].
  /// Отслеживаются отдельно от [_enrichmentInFlight]: они не участвуют в
  /// волне обогащения (не держат семафор), но `flushEnrichmentForTesting`
  /// обязан их дождаться, иначе тест завершится раньше, чем пропагация
  /// доедет до чужого репозитория (гонка с закрытием БД в tearDown).
  final Set<Future<void>> _crossArtworkPropagation = {};

  final List<({String globalId, String url})> _pendingArtwork = [];
  Timer? _artworkFlushTimer;

  /// Future всей волны [_refreshArtworkCandidates] (включая фазу сбора
  /// кандидатов по TTL). Нужен тестовому хуку [flushEnrichmentForTesting],
  /// чтобы дождаться ВСЕЙ волны, а не только уже запущенных in-flight
  /// запросов.
  Future<void>? _refreshFuture;

  /// Инкрементируется при сбросе обложек / сбросе состояния. In-flight
  /// результаты с устаревшим значением не применяются — защита от гонки
  /// «очистили кэш обложек, а прилетевший URL вернул обложку обратно».
  int _artworkGeneration = 0;

  /// Поток записей истории, новые сверху.
  Stream<List<HistoryEntry>> get stream => _controller.stream;

  /// Текущий снимок. Безопасно читать после `ensureLoaded()`.
  List<HistoryEntry> get current => List.unmodifiable(_list);

  /// Текущий лимит записей (1..[maxLimit]).
  int get limit => _limit;

  Future<void> ensureLoaded() {
    _initFuture ??= _load();
    return _initFuture!;
  }

  /// Сбрасывает кэш и перезагружает историю из БД.
  /// Вызывается после импорта полного бэкапа, чтобы UI отразил новые данные.
  Future<void> reload() async {
    _initFuture = null;
    await _load();
  }

  Future<void> _load() async {
    // Читаем лимит из SQLite settings.
    final rawLimit = await AppDatabase.instance.getSetting('history_limit_v1');
    _limit = int.tryParse(rawLimit ?? '') ?? defaultLimit;
    _limit = _limit.clamp(1, maxLimit);

    // Загружаем историю из БД.
    try {
      _list = await AppDatabase.instance.loadListenHistory(_limit);
    } catch (_) {
      _list = [];
    }
    _controller.add(List.unmodifiable(_list));

    // Лениво дозагружаем/обновляем обложки в фоне, не блокируя UI.
    unawaited(_refreshArtworkCandidates());
  }

  // Общие мутации (add/remove/clear) пишутся атомарно через AppDatabase,
  // debounce не нужен. Фоновое обогащение обложек батчится отдельно —
  // см. _refreshArtworkCandidates / _applyArtworkUpdates.

  // ===== Фоновое обогащение обложек =====

  /// Лениво дозагружает/обновляет обложки в истории прослушивания.
  ///
  /// Кандидаты на перезапрос:
  /// - записи БЕЗ обложки (`artworkUrl == null` / пустой);
  /// - записи с ПРОВАЙДЕРСКОЙ обложкой (Genius/iTunes, определяется через
  ///   [ArtworkProvider.isProviderArtworkUrl]), у которой в кэше провайдера
  ///   либо истёк TTL [ArtworkProvider.foundUrlTtl] (нужен перезапрос сети),
  ///   либо лежит ДРУГОЙ свежий URL (рассинхрон — обновляем без сети, чтобы
  ///   история и плейлисты показывали одну и ту же актуальную обложку).
  ///
  /// Что НЕ перезапрашивается: обложки, которые дал сам источник (SoundCloud
  /// `sndcdn.com`, YouTube `i.ytimg.com`, локальные файлы `/...` и `file://...`),
  /// и свежие совпадающие провайдерские URL — Genius/iTunes не дёргаются
  /// на каждый старт.
  ///
  /// Фоновое обогащение ограничено: не более [_maxEnrichPerLoad] треков за
  /// один вызов и не более [_maxEnrichConcurrency] одновременных запросов,
  /// чтобы старт приложения не превращался в сетевой шторм.
  Future<void> _refreshArtworkCandidates({bool force = false}) {
    return _refreshFuture = _refreshArtworkCandidatesAsync(force: force);
  }

  Future<void> _refreshArtworkCandidatesAsync({required bool force}) async {
    final candidates = <Track>[];
    final seen = <String>{};

    // 1. Быстрые кандидаты: записи без обложки (не требуют сети/TTL-проверки).
    for (final e in _list) {
      final t = e.track;
      if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
      final isMissing = t.artworkUrl == null || t.artworkUrl!.isEmpty;
      if (!isMissing) continue;
      if (seen.add(t.globalId)) candidates.add(t);
    }

    // 2. Кандидаты «провайдерская, но устарела по TTL ИЛИ рассинхронизирована».
    //    Собираем асинхронно (проверка кэша читает SQLite без сети), батчами
    //    через Future.wait, не блокируя UI.
    if (!force) {
      final checks = <Future<void>>[];
      for (final e in _list) {
        final t = e.track;
        final url = t.artworkUrl;
        if (url == null || url.isEmpty) continue;
        if (!ArtworkProvider.isProviderArtworkUrl(url)) continue;
        if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
        if (!seen.add(t.globalId)) continue;
        checks.add(
          ArtworkProvider.instance
              .getFreshCachedArtworkUrl(t.artist, t.title)
              .then((cached) {
            // Свежий кэш, совпадающий с хранимым URL — менять нечего.
            if (cached != null && cached == url) return;
            candidates.add(t);
          }),
        );
      }
      if (checks.isNotEmpty) await Future.wait(checks);
    } else {
      // force: перезапрашиваем ВСЕ провайдерские обложки, TTL игнорируем
      // (обычный «сброс обложек» в UI).
      for (final e in _list) {
        final t = e.track;
        final url = t.artworkUrl;
        if (url == null || url.isEmpty) continue;
        if (!ArtworkProvider.isProviderArtworkUrl(url)) continue;
        if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
        if (!seen.add(t.globalId)) continue;
        candidates.add(t);
      }
    }

    for (final track in candidates.take(_maxEnrichPerLoad)) {
      final future = _fetchAndApplyArtworkForTrack(track);
      _enrichmentInFlight.add(future);
      unawaited(future.whenComplete(() => _enrichmentInFlight.remove(future)));
    }
  }

  Future<void> _fetchAndApplyArtworkForTrack(Track track) async {
    // Семафор ограничивает одновременные запросы: каждый findArtwork даёт
    // до 2 параллельных HTTP-запросов (Genius + iTunes).
    await _enrichSemaphore.acquire();
    final generation = _artworkGeneration;
    try {
      // Сначала пробуем восстановить «родную» обложку из самого источника
      // (например, SoundCloud по ID трека): для таких треков Genius/iTunes
      // часто пусты, а без источника потерянный URL уже не вернуть.
      String? url;
      try {
        url = await SourceRegistry.instance
            .get(track.sourceId)
            ?.resolveArtwork(track);
      } catch (_) {
        url = null;
      }
      if (url == null || url.isEmpty) {
        url = await ArtworkProvider.instance.findArtwork(
          track.artist,
          track.title,
          preferredSize: 600,
        );
      }
      // Пока запрос летел, обложки могли сбросить (очистка кэша) или историю
      // перезагрузить — устаревший результат не применяем.
      if (generation != _artworkGeneration) return;
      if (url == null || url.isEmpty) return;
      _queueArtworkUpdate(track.globalId, url);
    } catch (_) {
      // Индивидуальные ошибки провайдера не роняют весь enrichment.
    } finally {
      _enrichSemaphore.release();
    }
  }

  /// Копит найденные обложки и применяет их одной пачкой через
  /// [_artworkFlushInterval] — один emit в стрим и одна серия записей в БД.
  void _queueArtworkUpdate(String globalId, String url) {
    _pendingArtwork.add((globalId: globalId, url: url));
    _artworkFlushTimer ??= Timer(_artworkFlushInterval, _flushArtworkBatch);
  }

  void _flushArtworkBatch() {
    _artworkFlushTimer = null;
    if (_pendingArtwork.isEmpty) return;
    final batch = List.of(_pendingArtwork);
    _pendingArtwork.clear();
    _applyArtworkUpdates(batch);
  }

  /// Применяет пачку обновлений обложек одним проходом: один emit в стрим
  /// и запись в БД. При дублях globalId внутри пачки побеждает последний URL.
  ///
  /// Применённые URL дополнительно пробрасываются в [PlaylistRepository],
  /// чтобы один и тот же трек показывал одну и ту же обложку во всём
  /// приложении (плейлисты ↔ история). Обновления идемпотентны, поэтому
  /// встречный проброс из плейлистов в историю (см. PlaylistRepository)
  /// циклично не размножается: после первого применения URL совпадают.
  void _applyArtworkUpdates(Iterable<({String globalId, String url})> updates) {
    final byGlobalId = <String, String>{};
    for (final u in updates) {
      byGlobalId[u.globalId] = u.url;
    }

    var changed = false;
    final newList = <HistoryEntry>[];
    for (final e in _list) {
      final url = byGlobalId[e.track.globalId];
      if (url != null && e.track.artworkUrl != url) {
        changed = true;
        newList.add(
          HistoryEntry(
            track: e.track.copyWith(artworkUrl: url),
            playedAt: e.playedAt,
          ),
        );
      } else {
        newList.add(e);
      }
    }

    if (changed) {
      _list = newList;
      unawaited(_persistArtworkUpdates(byGlobalId));
      _controller.add(List.unmodifiable(_list));
    }

    // Кросс-пропагация в плейлисты: даже если запись истории уже содержала
    // этот URL, плейлист мог сохранить старый — обложка одного трека должна
    // быть одинаковой во всём приложении.
    for (final u in updates) {
      _trackCrossArtworkPropagation(
        PlaylistRepository.instance.updateTrackArtwork(u.globalId, u.url),
      );
    }
  }

  /// Учитывает future кросс-пропагации в [_crossArtworkPropagation], чтобы
  /// тестовый хук [flushEnrichmentForTesting] дождался его завершения.
  void _trackCrossArtworkPropagation(Future<void> future) {
    _crossArtworkPropagation.add(future);
    unawaited(future.whenComplete(() => _crossArtworkPropagation.remove(future)));
  }

  Future<void> _persistArtworkUpdates(Map<String, String> byGlobalId) async {
    try {
      for (final e in byGlobalId.entries) {
        await AppDatabase.instance.updateListenHistoryArtwork(e.key, e.value);
      }
    } catch (_) {}
  }

  // ===== Mutations =====

  /// Добавляет трек в начало истории.
  ///
  /// Трек хранится в истории только один раз: при повторном прослушивании
  /// старая запись удаляется, а трек поднимается наверх со свежим `playedAt`.
  ///
  /// Операция идемпотентна и транзакционна на уровне БД: сначала пишем в БД,
  /// потом обновляем in-memory список. Если БД упадёт — память останется
  /// консистентной (изменения не применятся).
  Future<void> add(Track track) async {
    await ensureLoaded();
    final now = DateTime.now();
    final entry = HistoryEntry(track: track, playedAt: now);

    // Сначала атомарная запись в БД (DELETE + INSERT в одной транзакции).
    try {
      await AppDatabase.instance.addListenHistoryEntry(entry);
      await AppDatabase.instance.trimListenHistory(_limit);
    } catch (e, st) {
      debugPrint(
          '[HistoryRepository] Failed to persist history entry: $e\n$st');
      return; // Не обновляем память, если БД не приняла запись.
    }

    // Только после успешной записи обновляем in-memory список.
    _list = [
      entry,
      ..._list.where((e) => e.track.globalId != track.globalId),
    ];
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
    }

    _controller.add(List.unmodifiable(_list));
  }

  /// Удаляет одну запись.
  Future<void> remove(HistoryEntry entry) async {
    await ensureLoaded();
    final n = _list.length;
    _list = _list.where((e) => !e.sameAs(entry)).toList();
    if (_list.length != n) {
      await AppDatabase.instance.removeListenHistoryEntry(entry);
      _controller.add(List.unmodifiable(_list));
    }
  }

  /// Полностью очищает историю.
  Future<void> clear() async {
    await ensureLoaded();
    if (_list.isEmpty) return;
    _list = [];
    await AppDatabase.instance.clearListenHistory();
    _controller.add(List.unmodifiable(_list));
  }

  /// Меняет лимит записей. При уменьшении история сразу подрезается.
  Future<void> setLimit(int value) async {
    await ensureLoaded();
    final clamped = value.clamp(1, maxLimit);
    if (clamped == _limit) return;
    _limit = clamped;
    await AppDatabase.instance.setSetting('history_limit_v1', clamped.toString());
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
      await AppDatabase.instance.trimListenHistory(_limit);
      _controller.add(List.unmodifiable(_list));
    } else {
      _controller.add(List.unmodifiable(_list));
    }
  }

  /// Принудительный flush на диск (не нужен — все мутации атомарны).
  Future<void> flush() async {
    // no-op: все мутации атомарны.
  }

  /// Сбрасывает [artworkUrl] на null только у записей, чья обложка была
  /// найдена самим ArtworkProvider (Genius/iTunes), и сразу запускает фоновую
  /// дозагрузку обложек через [_refreshArtworkCandidates] принудительно
  /// (force), чтобы история снова заполнилась без ручного воспроизведения.
  ///
  /// Обложки, которые дал сам источник (SoundCloud `sndcdn.com`, YouTube
  /// `i.ytimg.com`, локальные файлы), НЕ сбрасываются: они стабильны.
  ///
  /// Вызывается из CachePage вместе с PlaylistRepository.resetAllTrackArtworks
  /// после очистки кэша URL обложек (ArtworkProvider.clearCache), чтобы
  /// история не осталась с «замороженным» провайдерским URL, пока плейлисты
  /// уже перезапросили свежие.
  void resetAllTrackArtworks() {
    _artworkGeneration++;
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();

    final cleared = <String>[];
    var anyChanged = false;
    final newList = <HistoryEntry>[];
    for (final e in _list) {
      final url = e.track.artworkUrl;
      // Сбрасываем ссылку на кастомную обложку, файл которой уже удалён
      // («Clear all cache» стёр custom_artworks/). Иначе в БД останется
      // мёртвый локальный путь и фоновое обогащение его не перезапросит —
      // трек останется без обложки. Живая кастомная обложка (файл на
      // диске есть, напр. ветка «Clear artwork cache») сохраняется.
      final isDeadCustom = url != null &&
          url.contains('custom_artworks') &&
          ArtworkHelper.getCustomArtworkSync(e.track.id) == null;
      if (url != null &&
          (ArtworkProvider.isProviderArtworkUrl(url) || isDeadCustom)) {
        anyChanged = true;
        cleared.add(e.track.globalId);
        newList.add(
          HistoryEntry(track: _withoutArtwork(e.track), playedAt: e.playedAt),
        );
      } else {
        newList.add(e);
      }
    }
    if (anyChanged) {
      _list = newList;
      unawaited(_persistClearedArtworks(cleared));
      _controller.add(List.unmodifiable(_list));
    }

    // Перезапускаем фоновую дозагрузку. После сброса кандидаты — все
    // сброшенные к null треки, а force=true перезапрашивает и оставшиеся
    // провайдерские обложки, не дожидаясь TTL. Старые in-flight запросы
    // уже инвалидированы инкрементом _artworkGeneration выше.
    unawaited(_refreshArtworkCandidates(force: true));
  }

  /// Копия трека без обложки. Нужна в [resetAllTrackArtworks]: обычный
  /// `copyWith(artworkUrl: null)` не сбрасывает URL — copyWith игнорирует null.
  static Track _withoutArtwork(Track t) => Track(
    id: t.id,
    sourceId: t.sourceId,
    title: t.title,
    artist: t.artist,
    duration: t.duration,
    artworkUrl: null,
    qualityScore: t.qualityScore,
    qualityLabel: t.qualityLabel,
    extra: t.extra,
  );

  Future<void> _persistClearedArtworks(List<String> globalIds) async {
    try {
      for (final gid in globalIds) {
        await AppDatabase.instance.updateListenHistoryArtwork(gid, null);
      }
    } catch (_) {}
  }

  /// Тестовый хук: сбрасывает внутреннее состояние (отменяет фоновое
  /// обогащение, накопленный батч и очищает таблицу истории).
  @visibleForTesting
  Future<void> resetForTesting() async {
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();
    _crossArtworkPropagation.clear();
    _refreshFuture = null;
    _artworkGeneration++;
    _initFuture = null;
    _list = [];
    try {
      await AppDatabase.instance.clearListenHistory();
    } catch (_) {}
    _controller.add(List.unmodifiable(_list));
  }

  /// Тестовый хук: дожидается завершения ВСЕЙ волны обогащения обложек —
  /// сначала фазы сбора кандидатов ([_refreshFuture]), затем всех in-flight
  /// запросов — и применяет накопленный батч, не ожидая [_artworkFlushInterval].
  @visibleForTesting
  Future<void> flushEnrichmentForTesting() async {
    // Ждём всю волну обогащения.
    await _refreshFuture;
    while (_enrichmentInFlight.isNotEmpty) {
      await Future.wait(List.of(_enrichmentInFlight));
    }
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _flushArtworkBatch();
    // Ждём КРОСС-пропагацию: пачка уже применена, но обновления, ушедшие
    // в PlaylistRepository (unawaited), могут ещё читать/писать БД. Если их
    // не дождаться, tearDown закроет БД раньше, чем они завершатся, —
    // «Bad state: This database has already been closed» и тест падает уже
    // после завершения.
    while (_crossArtworkPropagation.isNotEmpty) {
      await Future.wait(List.of(_crossArtworkPropagation));
    }
  }

  /// Обновляет [artworkUrl] у всех записей истории для трека с указанным
  /// [globalId]. Вызывается после ленивой подгрузки обложки через
  /// [ArtworkProvider].
  Future<void> updateTrackArtwork(String globalId, String artworkUrl) async {
    var changed = false;
    final newList = <HistoryEntry>[];
    for (final e in _list) {
      if (e.track.globalId == globalId && e.track.artworkUrl != artworkUrl) {
        changed = true;
        final updatedTrack = e.track.copyWith(artworkUrl: artworkUrl);
        newList.add(HistoryEntry(track: updatedTrack, playedAt: e.playedAt));
      } else {
        newList.add(e);
      }
    }
    if (changed) {
      _list = newList;
      unawaited(_persistArtworkUpdates({globalId: artworkUrl}));
      _controller.add(List.unmodifiable(_list));
    }
  }
}

/// Простой семафор с фиксированным числом слотов — ограничивает число
/// одновременных фоновых запросов обложек (см. [_maxEnrichConcurrency]).
class _Semaphore {
  _Semaphore(this._slots);

  final int _slots;
  int _used = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_used < _slots) {
      _used++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _used--;
    }
  }
}