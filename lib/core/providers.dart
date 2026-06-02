import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import '../sources/muzmo_source.dart';
import '../sources/source_registry.dart';
import 'player_service.dart';
import 'playlist_repository.dart';

/// PlayerService инициализируется в main.dart и пробрасывается сюда через
/// override. См. main.dart -> ProviderScope(overrides: [...]).
final playerServiceProvider = Provider<PlayerService>((ref) {
  throw UnimplementedError('Override in ProviderScope');
});

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

  const SearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.error,
    this.sourceId = kAllSourcesId,
  });

  SearchState copyWith({
    String? query,
    List<Track>? results,
    bool? loading,
    String? error,
    String? sourceId,
  }) => SearchState(
    query: query ?? this.query,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    error: error,
    sourceId: sourceId ?? this.sourceId,
  );
}

class SearchController extends StateNotifier<SearchState> {
  SearchController() : super(const SearchState());

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

  Future<void> search(String query, {String? sourceId}) async {
    if (query.trim().isEmpty) {
      // Сбрасываем результаты, но сохраняем выбранный фильтр.
      state = SearchState(sourceId: state.sourceId);
      return;
    }
    final useSource = sourceId ?? state.sourceId;
    state = state.copyWith(query: query, loading: true, error: null);
    final myQuery = query;

    // Хелпер: актуален ли ещё этот поиск (пользователь не сменил запрос
    // или источник за время сетевого запроса).
    bool isStale() => state.query != myQuery || state.sourceId != useSource;

    try {
      if (useSource == kAllSourcesId) {
        await _searchAll(myQuery, isStale);
      } else {
        await _searchOne(useSource, myQuery, isStale);
      }
    } catch (e) {
      if (state.query != myQuery) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Поиск в одном конкретном источнике.
  Future<void> _searchOne(
    String sourceId,
    String query,
    bool Function() isStale,
  ) async {
    final source = SourceRegistry.instance.require(sourceId);
    final results = await source.search(query);
    if (isStale()) return;
    state = state.copyWith(results: results, loading: false);
    _enrichMuzmo(source, results, query);
  }

  /// Поиск во всех зарегистрированных источниках сразу. Результаты
  /// объединяются «вперемешку»: по одному треку из каждого источника по
  /// кругу — так выдача не оказывается забита одним источником сверху.
  Future<void> _searchAll(String query, bool Function() isStale) async {
    final sources = SourceRegistry.instance.all;
    // Запускаем поиск во всех источниках параллельно. Падение одного не
    // должно ронять остальные — ошибки гасим в пустой список.
    final lists = await Future.wait(
      sources.map((s) async {
        try {
          return await s.search(query);
        } catch (_) {
          return <Track>[];
        }
      }),
    );
    if (isStale()) return;

    final merged = _interleave(lists);
    state = state.copyWith(results: merged, loading: false);

    // Обогащаем обложками те источники, что это поддерживают (Muzmo).
    for (final source in sources) {
      _enrichMuzmo(source, merged, query);
    }
  }

  /// Round-robin слияние нескольких списков в один.
  List<Track> _interleave(List<List<Track>> lists) {
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

  /// Запускает фоновое обогащение обложками для треков Muzmo внутри
  /// [results]. Для не-Muzmo источников — no-op.
  void _enrichMuzmo(dynamic source, List<Track> results, String query) {
    if (source is! MuzmoSource) return;
    // Обогащаем только треки этого источника (важно для режима «all»,
    // где в списке намешаны треки разных источников).
    final muzmoTracks =
        results.where((t) => t.sourceId == source.id).toList();
    if (muzmoTracks.isEmpty) return;

    source.enrichArtworksInBackground(muzmoTracks, (updated) {
      // Игнорируем колбэки от устаревшего поиска.
      if (state.query != query) return;
      // Вклеиваем обновлённые треки обратно в общий список по globalId,
      // сохраняя исходный порядок (важно для режима «all»).
      final byId = {for (final t in updated) t.globalId: t};
      final patched = [
        for (final t in state.results) byId[t.globalId] ?? t,
      ];
      state = state.copyWith(results: patched);
    });
  }
}

final searchProvider = StateNotifierProvider<SearchController, SearchState>((
  ref,
) {
  return SearchController();
});

/// Поток всех пользовательских плейлистов. UI слушает через
/// `ref.watch(playlistsProvider)` и получает `AsyncValue<List<Playlist>>`.
final playlistsProvider = StreamProvider<List<Playlist>>((ref) async* {
  // Гарантируем, что данные подняты с диска до первого emit.
  await PlaylistRepository.instance.ensureLoaded();
  yield PlaylistRepository.instance.current;
  yield* PlaylistRepository.instance.stream;
});

/// Удобный доступ к репозиторию из UI: для мутаций.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository.instance;
});
