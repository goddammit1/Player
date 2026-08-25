import 'dart:async';

import '../models/playlist.dart';
import '../models/track.dart';
import '../sources/artwork_provider.dart';
import '../sources/source_registry.dart';
import 'artwork_helper.dart';
import 'repositories/history_repository.dart';

/// Фоновое обогащение обложек плейлистов — выделено из [PlaylistRepository],
/// чтобы репозиторий оставался чистым хранилищем/мутатором.
///
/// Владелец (PlaylistRepository) конфигурирует этот класс двумя колбэками:
/// - [readPlaylists] — вернуть текущий список плейлистов;
/// - [applyPlaylists] — принять изменённый список и уведомить подписчиков.
///
/// Внутреннее состояние (семафор, in-flight запросы, накопленный батч,
/// таймер флаша, поколение) полностью приватно для этого класса.
class PlaylistArtworkEnricher {
  PlaylistArtworkEnricher._();
  static final PlaylistArtworkEnricher instance = PlaylistArtworkEnricher._();

  /// Максимум одновременных фоновых запросов обложек. Каждый трек внутри
  /// [ArtworkProvider.findArtwork] даёт 2 параллельных HTTP-запроса
  /// (Genius + iTunes), поэтому даже 3 слота = 6 запросов в один момент.
  static const int _maxEnrichConcurrency = 3;

  /// Сколько треков без обложек обогащается за один `refreshFetch()`. Предохраняет
  /// от сетевого шторма на старте приложения при большой библиотеке.
  static const int _maxEnrichPerLoad = 50;

  /// Частота применения накопленного батча обложек: пачка найденных URL
  /// применяется одним эмитом в стрим и одной записью в БД.
  static const Duration _artworkFlushInterval = Duration(milliseconds: 150);

  /// Колбэки, настраиваются владельцем (PlaylistRepository).
  List<Playlist> Function() readPlaylists = () => <Playlist>[];
  void Function(List<Playlist> next) applyPlaylists = (_) {};

  final _Semaphore _enrichSemaphore = _Semaphore(_maxEnrichConcurrency);
  final Set<Future<void>> _enrichmentInFlight = {};

  /// Хвостовые задачи кросс-пропагации обложек в [HistoryRepository].
  /// См. комментарий в HistoryRepository._crossArtworkPropagation.
  final Set<Future<void>> _crossArtworkPropagation = {};

  final List<({String globalId, String url})> _pendingArtwork = [];
  Timer? _artworkFlushTimer;

  /// Future всей волны [refreshArtworkCandidates] (включая фазу сбора
  /// кандидатов по TTL). Нужен тестовому хуку [flushEnrichmentForTesting],
  /// чтобы дождаться ВСЕЙ волны, а не только уже запущенных in-flight
  /// запросов.
  Future<void>? _refreshFuture;

  /// Инкрементируется при сбросе обложек / сбросе состояния. In-flight
  /// результаты с устаревшим значением не применяются — защита от гонки
  /// «очистили кэш обложек, а прилетевший URL вернул обложку обратно».
  int _artworkGeneration = 0;

  /// Запускает волну ленивой дозагрузки/обновления обложек.
  Future<void> refreshArtworkCandidates({bool force = false}) {
    return _refreshFuture = _refreshArtworkCandidatesAsync(force: force);
  }

  Future<void> _refreshArtworkCandidatesAsync({required bool force}) async {
    final candidates = <Track>[];
    final seen = <String>{};

    // 1. Быстрые кандидаты: треки без обложки (не требуют сети/TTL-проверки).
    for (final p in readPlaylists()) {
      for (final t in p.tracks) {
        if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
        final isMissing = t.artworkUrl == null || t.artworkUrl!.isEmpty;
        if (!isMissing) continue;
        if (seen.add(t.globalId)) candidates.add(t);
      }
    }

    // 2. Кандидаты «провайдерская, но устарела по TTL ИЛИ рассинхронизирована».
    //    Собираем их асинхронно (проверка кэша читает SQLite без сети),
    //    не блокируя UI — батчами через Future.wait.
    if (!force) {
      final staleChecks = <Future<void>>[];
      for (final p in readPlaylists()) {
        for (final t in p.tracks) {
          final url = t.artworkUrl;
          if (url == null || url.isEmpty) continue;
          if (!ArtworkProvider.isProviderArtworkUrl(url)) continue;
          if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
          if (!seen.add(t.globalId)) continue;
          staleChecks.add(
            ArtworkProvider.instance
                .getFreshCachedArtworkUrl(t.artist, t.title)
                .then((cached) {
                  // Свежий кэш, совпадающий с хранимым URL — менять нечего.
                  if (cached != null && cached == url) return;
                  candidates.add(t);
                }),
          );
        }
      }
      if (staleChecks.isNotEmpty) {
        await Future.wait(staleChecks);
      }
    } else {
      // force: перезапрашиваем ВСЕ провайдерские, TTL игнорируем.
      for (final p in readPlaylists()) {
        for (final t in p.tracks) {
          final url = t.artworkUrl;
          if (url == null || url.isEmpty) continue;
          if (!ArtworkProvider.isProviderArtworkUrl(url)) continue;
          if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
          if (seen.add(t.globalId)) candidates.add(t);
        }
      }
    }

    for (final track in candidates.take(_maxEnrichPerLoad)) {
      final future = _fetchAndApplyArtworkForTrack(track);
      _enrichmentInFlight.add(future);
      unawaited(future.whenComplete(() => _enrichmentInFlight.remove(future)));
    }
  }

  Future<void> _fetchAndApplyArtworkForTrack(Track track) async {
    // Семафор ограничивает одновременные запросы: в плейлистах могут быть
    // сотни треков без обложек, а каждый findArtwork даёт 2 параллельных
    // HTTP-запроса (Genius + iTunes). Без лимита старт приложения = десятки
    // одновременных запросов → rate-limits и тормоза сети/UI.
    await _enrichSemaphore.acquire();
    final generation = _artworkGeneration;
    try {
      // Сначала пробуем восстановить «родную» обложку из самого источника
      // (например, SoundCloud по ID трека): для таких треков Genius/iTunes
      // часто пуст, а без источника потерянный URL уже не вернуть.
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
      // Пока запрос летел, обложки могли сбросить (очистка кэша) или
      // плейлисты перезагрузить — устаревший результат не применяем,
      // иначе «сброс» откатился бы прилетевшим URL.
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
  /// [_artworkFlushInterval] — один emit в стрим и один persist на пачку.
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
  /// и один дебаунс-персист. При дублях globalId внутри пачки побеждает
  /// последний URL.
  ///
  /// Применённые URL дополнительно пробрасываются в [HistoricalRepository],
  /// чтобы один и тот же трек показывал одну и ту же обложку во всём
  /// приложении (плейлисты ↔ история). Обновления идемпотентны, поэтому
  /// встречный проброс из истории в плейлисты (см. HistoryRepository)
  /// циклично не размножается: после первого применения URL совпадают.
  void _applyArtworkUpdates(Iterable<({String globalId, String url})> updates) {
    final byGlobalId = <String, String>{};
    for (final u in updates) {
      byGlobalId[u.globalId] = u.url;
    }

    var changed = false;
    final newList = <Playlist>[];
    for (final p in readPlaylists()) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        final url = byGlobalId[t.globalId];
        if (url != null && t.artworkUrl != url) {
          playlistChanged = true;
          return t.copyWith(artworkUrl: url);
        }
        return t;
      }).toList();
      if (playlistChanged) changed = true;
      newList.add(playlistChanged ? p.copyWith(tracks: newTracks) : p);
    }
    if (changed) applyPlaylists(newList);

    // Кросс-пропагация в историю: даже если ни один плейлист не изменился,
    // история может держать старый URL для того же globalId.
    for (final u in updates) {
      _trackCrossArtworkPropagation(
        HistoryRepository.instance.updateTrackArtwork(u.globalId, u.url),
      );
    }
  }

  /// Учитывает future кросс-пропагации в [_crossArtworkPropagation], чтобы
  /// тестовый хук [flushEnrichmentForTesting] дождался его завершения.
  void _trackCrossArtworkPropagation(Future<void> future) {
    _crossArtworkPropagation.add(future);
    unawaited(future.whenComplete(() => _crossArtworkPropagation.remove(future)));
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

  /// Обновляет [artworkUrl] у трека с указанным [globalId] во всех плейлистах,
  /// где он встречается. Вызывается после ленивой подгрузки обложки через
  /// [ArtworkProvider], чтобы обложка попала в БД и отображалась в плейлистах.
  Future<void> updateTrackArtwork(String globalId, String artworkUrl) async {
    _applyArtworkUpdates([(globalId: globalId, url: artworkUrl)]);
  }

  /// Сбрасывает [artworkUrl] на null только у тех треков, чья обложка
  /// была найдена самим ArtworkProvider (Genius/iTunes), и сразу
  /// запускает фоновую дозагрузку обложек через [refreshArtworkCandidates]
  /// принудительно (force), чтобы плейлисты снова заполнились без ручного
  /// воспроизведения каждого трека.
  ///
  /// Обложки, которые дал сам источник (SoundCloud `sndcdn.com`,
  /// YouTube `i.ytimg.com`, локальные файлы `/...` и `file://...`),
  /// НЕ сбрасываются: они стабильны, и после очистки дискового кэша
  /// CachedNetworkImage скачает их заново по тому же URL. Также отменяет
  /// накопленный батч и инвалидирует in-flight запросы, чтобы URL,
  /// прилетевшие ДО сброса, не вернули обложки обратно; запросы, запущенные
  /// самим сбросом (уже после инкремента [_artworkGeneration]), применяются
  /// как обычно.
  void resetAllTrackArtworks() {
    _artworkGeneration++;
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();

    var anyChanged = false;
    final newList = <Playlist>[];
    for (final p in readPlaylists()) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        final url = t.artworkUrl;
        // Сбрасываем ссылку на кастомную обложку, файл которой уже удалён
        // («Clear all cache» стёр custom_artworks/). Иначе в БД останется
        // мёртвый локальный путь и фоновое обогащение его не перезапросит —
        // трек останется без обложки. Живая кастомная обложка (файл на
        // диске есть, напр. ветка «Clear artwork cache») сохраняется.
        final isDeadCustom = url != null &&
            url.contains('custom_artworks') &&
            ArtworkHelper.getCustomArtworkSync(t.id) == null;
        if (url != null &&
            (ArtworkProvider.isProviderArtworkUrl(url) || isDeadCustom)) {
          playlistChanged = true;
          return _withoutArtwork(t);
        }
        return t;
      }).toList();
      if (playlistChanged) {
        anyChanged = true;
        newList.add(p.copyWith(tracks: newTracks));
      } else {
        newList.add(p);
      }
    }
    if (anyChanged) applyPlaylists(newList);

    // Перезапускаем фоновую дозагрузку. После сброса обложек кандидаты —
    // все треки (и сброшенные к null, и оставшиеся), а force=true
    // перезапрашивает ВСЕ провайдерские обложки, не дожидаясь TTL.
    // Старые in-flight запросы уже инвалидированы инкрементом
    // _artworkGeneration выше, поэтому их результаты не применятся.
    unawaited(refreshArtworkCandidates(force: true));
  }

  /// Тестовый хук: дожидается завершения ВСЕЙ волны обогащения обложек —
  /// сначала фазы сбора кандидатов ([_refreshFuture]), затем всех in-flight
  /// запросов — и применяет накопленный батч, не ожидая [_artworkFlushInterval].
  Future<void> flushEnrichmentForTesting() async {
    // Дожидаемся фазы сбора кандидатов (может включать TTL-проверки) и всех
    // in-flight запросов волны обогащения.
    await _refreshFuture;
    while (_enrichmentInFlight.isNotEmpty) {
      await Future.wait(List.of(_enrichmentInFlight));
    }
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _flushArtworkBatch();
    // Ждём КРОСС-пропагацию в HistoryRepository (см. комментарий в
    // HistoryRepository.flushEnrichmentForTesting) — иначе tearDown закроет
    // БД раньше, чем хвостовая задача прочитает/запишет её.
    while (_crossArtworkPropagation.isNotEmpty) {
      await Future.wait(List.of(_crossArtworkPropagation));
    }
  }

  /// Сбрасывает внутреннее состояние обогащения (для тестов и аварийного
  /// восстановления). Владелец отвечает за своё состояние (список, таймер).
  void resetForTesting() {
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();
    _crossArtworkPropagation.clear();
    _refreshFuture = null;
    _artworkGeneration++;
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