import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/track.dart';
import '../sources/muzmo_source.dart';
import '../sources/soulseek_source.dart';
import '../sources/soundcloud_source.dart';
import '../sources/source_registry.dart';
import '../sources/track_source.dart';

/// Виртуальный id «искать во всех источниках сразу». Не зарегистрирован в
/// [SourceRegistry] — обрабатывается в [SearchController] отдельно.
const String kAllSourcesId = 'all';

/// Стейт текущего поиска.
///
/// [sourceId] хранится прямо в стейте (а не в приватном поле контроллера),
/// чтобы UI через `ref.watch(searchProvider)` перерисовывал активный фильтр
/// даже когда поисковый запрос пуст и реального перепоиска не происходит.
class SearchState {
  final String query;
  final List<Track> results;
  final bool loading;
  final String? error;
  final String sourceId;

  /// Результаты медленных источников в режиме «Все» (Soulseek) — отдельная
  /// секция под основной выдачей. Они приходят на секунды позже остальных;
  /// вклейка в [results] сдвигала бы уже показанные треки под пальцем.
  final List<Track> isolatedResults;

  /// Изолированные источники ещё ищут — UI держит под секцию плейсхолдер.
  final bool isolatedLoading;

  const SearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.error,
    this.sourceId = kAllSourcesId,
    this.isolatedResults = const [],
    this.isolatedLoading = false,
  });

  /// Основная выдача + изолированная секция в порядке показа на экране
  /// (очередь воспроизведения, поиск трека по globalId).
  List<Track> get allResults =>
      isolatedResults.isEmpty ? results : [...results, ...isolatedResults];

  SearchState copyWith({
    String? query,
    List<Track>? results,
    bool? loading,
    String? error,
    String? sourceId,
    List<Track>? isolatedResults,
    bool? isolatedLoading,
  }) => SearchState(
    query: query ?? this.query,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    error: error,
    sourceId: sourceId ?? this.sourceId,
    isolatedResults: isolatedResults ?? this.isolatedResults,
    isolatedLoading: isolatedLoading ?? this.isolatedLoading,
  );
}

class SearchController extends StateNotifier<SearchState> {
  SearchController({
    this.isolatedSourceIds = const {SoulseekSource.sourceId},
  }) : super(const SearchState());

  /// Источники, которые в режиме «Все» не смешиваются с основной выдачей,
  /// а показываются отдельной секцией ([SearchState.isolatedResults]).
  final Set<String> isolatedSourceIds;

  /// Монотонный счётчик поколений поиска. Каждый новый запрос/смена
  /// источника инкрементирует его, чтобы stale-колбэки от старых futures
  /// не могли изменить актуальный state.
  int _searchGeneration = 0;

  /// Текущий выбранный источник (или [kAllSourcesId]).
  String get sourceId => state.sourceId;

  void setSourceId(String id) {
    if (state.sourceId == id) return;
    // Обновляем стейт сразу — это перерисует активный фильтр в UI даже
    // при пустом запросе (раньше менялось приватное поле, и watch не
    // срабатывал, из-за чего фильтры «не переключались» до ввода текста).
    state = state.copyWith(sourceId: id);
    // Если был активный запрос — перепоиск в новом источнике, чтобы
    // пользователь сразу видел релевантные результаты.
    if (state.query.trim().isNotEmpty) {
      search(state.query);
    }
  }

  /// Отмена подписок на потоковые источники текущего поиска. Отписка от
  /// [ProgressiveSearchSource.searchProgressive] отменяет и сам нативный
  /// P2P-поиск — он не держит слот поиска и канал до конца бюджета.
  final List<void Function()> _activeCancels = [];

  void _cancelActiveSearches() {
    final cancels = List.of(_activeCancels);
    _activeCancels.clear();
    for (final cancel in cancels) {
      cancel();
    }
  }

  /// globalId треков, уже отправленных на обогащение обложками в текущем
  /// поиске. Потоковый источник присылает десятки снимков — без этого
  /// каждый снимок заново запрашивал бы обложки ненайденных треков.
  final Set<String> _artworkRequested = {};

  @override
  void dispose() {
    _cancelActiveSearches();
    super.dispose();
  }

  Future<void> search(String query, {String? sourceId}) async {
    // Отписка ДО новых подписок: если новый поиск тот же (смена чипа
    // «Все» → «Soulseek»), источник присоединит его к идущему P2P-поиску.
    _cancelActiveSearches();
    _artworkRequested.clear();
    if (query.trim().isEmpty) {
      // Сбрасываем результаты, но сохраняем выбранный фильтр.
      ++_searchGeneration;
      state = SearchState(sourceId: state.sourceId);
      return;
    }
    final useSource = sourceId ?? state.sourceId;
    final generation = ++_searchGeneration;
    // Изолированную секцию сбрасываем сразу: иначе под новой основной
    // выдачей висели бы Soulseek-треки прошлого запроса.
    state = state.copyWith(
      query: query,
      loading: true,
      error: null,
      isolatedResults: const [],
      isolatedLoading: false,
    );
    final myQuery = query;

    // Хелпер: актуален ли ещё этот поиск (пользователь не сменил запрос
    // или источник за время сетевого запроса).
    bool isStale() =>
        _searchGeneration != generation ||
        state.query != myQuery ||
        state.sourceId != useSource;

    try {
      if (useSource == kAllSourcesId) {
        await _searchAll(myQuery, generation, isStale);
      } else {
        await _searchOne(useSource, myQuery, generation, isStale);
      }
    } catch (e) {
      if (isStale()) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Поиск в одном конкретном источнике.
  Future<void> _searchOne(
    String sourceId,
    String query,
    int generation,
    bool Function() isStale,
  ) async {
    final source = SourceRegistry.instance.require(sourceId);
    final timeout = _timeoutFor(source, single: true);

    if (source is ProgressiveSearchSource) {
      // Снимки показываются по мере прихода; по таймауту остаётся последний.
      await _collect(source as ProgressiveSearchSource, query, timeout,
          (snapshot) {
        if (isStale()) return;
        state = state.copyWith(results: snapshot, loading: false);
        _enrichArtworksFromState(source, query, generation);
      });
      if (isStale()) return;
      if (state.loading) {
        state = state.copyWith(results: const [], loading: false);
      }
      return;
    }

    final List<Track> results;
    try {
      results = await source.search(query).timeout(timeout);
    } on TimeoutException {
      if (isStale()) return;
      state = state.copyWith(
        results: const [],
        loading: false,
        error: '${source.displayName}: no response in ${timeout.inSeconds} s',
      );
      return;
    }
    if (isStale()) return;
    state = state.copyWith(results: results, loading: false);
    // Передаём треки из state.results (а не сырые результаты), чтобы
    // при повторном поиске enrich видел уже известные artworkUrl и
    // пропускал треки с обложками, не гоняя лишние сетевые запросы.
    _enrichArtworksFromState(source, query, generation);
  }

  /// Таймаут на один источник в режиме «all».
  /// Оптимальный баланс: достаточно быстро для хорошего UX,
  /// но и достаточно, чтобы медленный, но рабочий источник успел ответить.
  static const _sourceTimeout = Duration(seconds: 5);

  /// Таймаут, когда источник выбран фильтром: пользователь ждёт именно его,
  /// поэтому щедрее, чем в «all», но зависнуть навсегда поиск не может.
  static const _singleSourceTimeout = Duration(seconds: 15);

  /// NEW-2: Soulseek — P2P-поиск, который C# bridge сам ограничивает
  /// общим бюджетом [SoulseekSource.searchTimeoutMs] и возвращает всё
  /// накопленное. Внешний таймаут берём с запасом на JNI/канал, иначе
  /// он отрезал бы уже собранные результаты. Результаты остальных
  /// источников показываются сразу — Soulseek доклеится позже.
  static const _soulseekTimeoutMargin = Duration(seconds: 3);

  /// Возвращает пер-источниковый таймаут (NEW-2: расширенный для Soulseek).
  /// [single] — источник выбран фильтром (см. [_singleSourceTimeout]).
  Duration _timeoutFor(TrackSource source, {bool single = false}) =>
      source is SoulseekSource
          ? Duration(milliseconds: source.searchTimeoutMs) +
              _soulseekTimeoutMargin
          : single
              ? _singleSourceTimeout
              : _sourceTimeout;

  /// Подписывается на потоковый [source] и отдаёт снимки в [onSnapshot].
  /// Завершается, когда поиск закончился, истёк [timeout] (последний снимок
  /// остаётся) или поиск отменён через [_cancelActiveSearches].
  Future<void> _collect(
    ProgressiveSearchSource source,
    String query,
    Duration timeout,
    void Function(List<Track> snapshot) onSnapshot,
  ) {
    final done = Completer<void>();
    late final StreamSubscription<List<Track>> sub;
    late final Timer timer;
    late final void Function() cancel;
    void finish() {
      timer.cancel();
      _activeCancels.remove(cancel);
      if (!done.isCompleted) done.complete();
    }

    cancel = () {
      sub.cancel();
      finish();
    };
    sub = source.searchProgressive(query).listen(
          onSnapshot,
          onError: (Object _) {},
          onDone: finish,
        );
    timer = Timer(timeout, cancel);
    _activeCancels.add(cancel);
    return done.future;
  }

  /// Поиск во всех зарегистрированных источниках сразу.
  ///
  /// Источники делятся на две группы, которые ищут параллельно:
  ///  - обычные — в [SearchState.results], по мере поступления (первый
  ///    ответивший снимает loading);
  ///  - изолированные ([isolatedSourceIds], Soulseek) — в отдельную секцию
  ///    [SearchState.isolatedResults] под основной выдачей. Они отвечают на
  ///    секунды позже, и вклейка в общий round-robin сдвигала бы уже
  ///    показанные треки.
  ///
  /// Медленные или недоступные источники (например, SoundCloud без прокси)
  /// тихо пропускаются по таймауту [_timeoutFor].
  Future<void> _searchAll(
    String query,
    int generation,
    bool Function() isStale,
  ) async {
    final sources = SourceRegistry.instance.searchable;
    final regular = [
      for (final s in sources)
        if (!isolatedSourceIds.contains(s.id)) s,
    ];
    final isolated = [
      for (final s in sources)
        if (isolatedSourceIds.contains(s.id)) s,
    ];

    // Без обычных источников основная выдача пуста сразу, а не после
    // ответа изолированных.
    if (regular.isEmpty) {
      state = state.copyWith(
        results: const [],
        loading: false,
        isolatedLoading: isolated.isNotEmpty,
      );
    } else if (isolated.isNotEmpty) {
      state = state.copyWith(isolatedLoading: true);
    }

    await Future.wait([
      if (regular.isNotEmpty)
        _mergeAsArriving(regular, query, generation, isStale, isolated: false),
      if (isolated.isNotEmpty)
        _mergeAsArriving(isolated, query, generation, isStale, isolated: true),
    ]);
  }

  /// Параллельно опрашивает [sources] и по мере ответов кладёт их
  /// round-robin слияние в [SearchState.results] или, при [isolated], в
  /// [SearchState.isolatedResults]. Round-robin — по одному треку из
  /// каждого источника по кругу, чтобы список не был забит одним источником.
  ///
  /// Потоковые источники ([ProgressiveSearchSource]) присылают несколько
  /// снимков — каждый сразу попадает в выдачу.
  Future<void> _mergeAsArriving(
    List<TrackSource> sources,
    String query,
    int generation,
    bool Function() isStale, {
    required bool isolated,
  }) async {
    final completed = List<bool>.filled(sources.length, false);
    final results = List<List<Track>>.filled(sources.length, const []);

    // Первый ответивший показываем сразу — сбрасываем loading.
    var firstResultShown = false;

    void apply(int index, List<Track> list) {
      if (isStale()) return;
      results[index] = list;

      // Round-robin слияние уже полученных результатов.
      final merged = SearchController.interleave(results);

      // ВАЖНО: слияние строится из исходных (необогащённых) списков.
      // Если обогащение обложками какого-то источника уже успело
      // пропатчить список в state (например, обложки взялись из кэша
      // мгновенно при повторном поиске), нельзя терять эти обложки —
      // переносим уже известные artworkUrl в новый merged-список.
      final current = isolated ? state.isolatedResults : state.results;
      final knownArt = <String, String>{
        for (final t in current)
          if (t.artworkUrl != null && t.artworkUrl!.isNotEmpty)
            t.globalId: t.artworkUrl!,
      };
      final mergedWithArt = [
        for (final t in merged)
          if ((t.artworkUrl == null || t.artworkUrl!.isEmpty) &&
              knownArt.containsKey(t.globalId))
            t.copyWith(artworkUrl: knownArt[t.globalId])
          else
            t,
      ];

      if (isolated) {
        // Секция держит плейсхолдер, пока не ответят все её источники.
        state = state.copyWith(
          isolatedResults: mergedWithArt,
          isolatedLoading: completed.contains(false),
        );
      } else if (!firstResultShown) {
        firstResultShown = true;
        // Первый источник ответил — показываем результаты и убираем
        // индикатор загрузки. Остальные придут позже и доклеятся.
        state = state.copyWith(results: mergedWithArt, loading: false);
      } else {
        // Последующие источники доклеиваются к уже показанным.
        state = state.copyWith(results: mergedWithArt);
      }

      // Запускаем обогащение обложками ПОСЛЕ установки списка в state,
      // чтобы enrich видел текущие artworkUrl (в т.ч. из кэша knownArt)
      // и повторно не гонял сеть для треков с уже известными обложками.
      _enrichArtworksFromState(sources[index], query, generation);
    }

    Future<void> run(int index) async {
      final s = sources[index];
      final timeout = _timeoutFor(s);
      if (s is ProgressiveSearchSource) {
        await _collect(s as ProgressiveSearchSource, query, timeout,
            (snapshot) => apply(index, snapshot));
        completed[index] = true;
        if (isolated && !isStale()) {
          state = state.copyWith(isolatedLoading: completed.contains(false));
        }
        return;
      }
      // Обычный источник обёрнут в таймаут — если не ответил вовремя,
      // возвращается пустой список (тихо, без ошибки в UI).
      List<Track> list;
      try {
        list = await s.search(query).timeout(timeout);
      } catch (_) {
        list = const [];
      }
      completed[index] = true;
      apply(index, list);
    }

    await Future.wait([for (var i = 0; i < sources.length; i++) run(i)]);

    // Все источники либо ответили, либо упали по таймауту.
    if (isStale()) return;
    if (isolated) {
      state = state.copyWith(isolatedLoading: false);
    } else if (!firstResultShown) {
      // Ни один не ответил — сбрасываем loading и показываем пустой список.
      state = state.copyWith(results: const [], loading: false);
    }
  }

  /// Round-robin слияние нескольких списков в один.
  static List<Track> interleave(List<List<Track>> lists) {
    final merged = <Track>[];
    var i = 0;
    var added = true;
    while (added) {
      added = false;
      for (final list in lists) {
        if (i < list.length) {
          merged.add(list[i]);
          added = true;
        }
      }
      i++;
    }
    return merged;
  }

  /// Запускает фоновое обогащение обложками для треков источников,
  /// которые это поддерживают (Muzmo, SoundCloud, Soulseek). Для
  /// остальных — no-op.
  ///
  /// ВАЖНО: треки берутся из **state.results** (а не из сырого ответа
  /// источника), чтобы при повторном поиске enrich видел уже известные
  /// artworkUrl и пропускал треки с обложками, не гоняя лишние сетевые
  /// запросы. Это же защищает от гонки, когда _searchAll перезаписывает
  /// state.results свежим merged-списком — обогащение применяется к
  /// актуальному состоянию UI.
  void _enrichArtworksFromState(
    dynamic source,
    String query,
    int generation,
  ) {
    final sourceId = source.id;
    // Только треки, ещё не отправленные на обогащение в этом поиске
    // (см. [_artworkRequested]).
    final sourceTracksInState = state.allResults
        .where((t) => t.sourceId == sourceId)
        .where((t) => _artworkRequested.add(t.globalId))
        .toList();
    if (sourceTracksInState.isEmpty) return;

    if (source is MuzmoSource) {
      source.enrichArtworksInBackground(
        sourceTracksInState,
        _patchResults(query, generation),
      );
    } else if (source is SoundCloudSource) {
      source.enrichArtworksInBackground(
        sourceTracksInState,
        _patchResults(query, generation),
      );
    } else if (source is SoulseekSource) {
      // P5: Soulseek не отдаёт обложки в выдаче — дозаполняем из
      // ArtworkProvider (Genius/iTunes) по artist/title.
      source.enrichArtworksInBackground(
        sourceTracksInState,
        _patchResults(query, generation),
      );
    }
  }

  /// Возвращает колбэк, который переносит найденные обложки обратно в
  /// общий список результатов по globalId, игнорируя устаревший поиск.
  ///
  /// Переносится только artworkUrl, а не трек целиком: обогащение работает
  /// с копией на момент запуска, а потоковый источник за это время мог
  /// обновить трек (например, `extra.peerCount`).
  ///
  /// [generation] — поколение поиска, при смене которого патч
  /// отбрасывается. Это защищает от ситуации, когда пользователь быстро
  /// сменил фильтр, но query остался прежним.
  void Function(List<Track>) _patchResults(String query, int generation) {
    return (updated) {
      // Игнорируем колбэки от устаревшего поиска.
      if (_searchGeneration != generation || state.query != query) return;
      final art = <String, String>{
        for (final t in updated)
          if (t.artworkUrl != null && t.artworkUrl!.isNotEmpty)
            t.globalId: t.artworkUrl!,
      };
      if (art.isEmpty) return;
      Track patch(Track t) {
        final url = art[t.globalId];
        return url == null || url == t.artworkUrl
            ? t
            : t.copyWith(artworkUrl: url);
      }

      // Оба списка (основной и изолированная секция), порядок сохраняется.
      state = state.copyWith(
        results: [for (final t in state.results) patch(t)],
        isolatedResults: [for (final t in state.isolatedResults) patch(t)],
      );
    };
  }
}

final searchProvider = StateNotifierProvider<SearchController, SearchState>((
  ref,
) {
  return SearchController();
});