import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import '../sources/muzmo_source.dart';
import '../sources/soundcloud_source.dart';
import '../sources/source_registry.dart';
import 'app_database.dart';
import 'history_repository.dart';
import 'player_service.dart';
import 'playlist_repository.dart';
export 'appearance_provider.dart';
export 'dynamic_colors.dart';
export 'global_theme_provider.dart';

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

  Future<void> search(String query, {String? sourceId}) async {
    if (query.trim().isEmpty) {
      // Сбрасываем результаты, но сохраняем выбранный фильтр.
      state = SearchState(sourceId: state.sourceId);
      return;
    }
    final useSource = sourceId ?? state.sourceId;
    final generation = ++_searchGeneration;
    state = state.copyWith(query: query, loading: true, error: null);
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
    final results = await source.search(query);
    if (isStale()) return;
    state = state.copyWith(results: results, loading: false);
    _enrichArtworks(source, results, query, generation);
  }

  /// Таймаут на один источник в режиме «all».
  /// Оптимальный баланс: достаточно быстро для хорошего UX,
  /// но и достаточно, чтобы медленный, но рабочий источник успел ответить.
  static const _sourceTimeout = Duration(seconds: 5);

  /// Поиск во всех зарегистрированных источниках сразу.
  ///
  /// Результаты показываются сразу по мере поступления — как только хотя
  /// бы один источник ответил, UI получает первую порцию. Медленные или
  /// недоступные источники (например, SoundCloud без VPN) тихо
  /// пропускаются по таймауту [_sourceTimeout].
  ///
  /// Финальная выдача объединяется round-robin: по одному треку из
  /// каждого источника по кругу — так список не забит одним источником.
  Future<void> _searchAll(
    String query,
    int generation,
    bool Function() isStale,
  ) async {
    final sources = SourceRegistry.instance.searchable;
    if (sources.isEmpty) {
      if (!isStale()) {
        state = state.copyWith(results: const [], loading: false);
      }
      return;
    }

    // Запускаем поиск в каждом источнике параллельно.
    // Каждый источник обёрнут в таймаут — если не ответил за 5 сек,
    // возвращается пустой список (тихо, без ошибки в UI).
    final futures = sources.map((s) async {
      try {
        return await s.search(query).timeout(_sourceTimeout);
      } catch (_) {
        return <Track>[];
      }
    }).toList();

    // Слушаем результаты по мере готовности через Stream.
    // Каждый future оборачиваем в пару (index, result), чтобы знать
    // какой источник ответил.
    final resultStream = Stream.fromFutures(
      List.generate(futures.length, (i) async {
        final list = await futures[i];
        return (i, list);
      }),
    );

    final completed = List<bool>.filled(futures.length, false);
    final results = List<List<Track>>.filled(futures.length, const []);

    // Первый ответивший показываем сразу — сбрасываем loading.
    var firstResultShown = false;

    await for (final (index, list) in resultStream) {
      if (isStale()) return;

      completed[index] = true;
      results[index] = list;

      // Round-robin слияние уже полученных результатов.
      final merged = SearchController.interleave(
        List.generate(results.length, (i) => completed[i] ? results[i] : const []),
      );

      // ВАЖНО: слияние строится из исходных (необогащённых) списков.
      // Если обогащение обложками какого-то источника уже успело
      // пропатчить state.results (например, обложки взялись из кэша
      // мгновенно при повторном поиске), нельзя терять эти обложки —
      // переносим уже известные artworkUrl в новый merged-список.
      final knownArt = <String, String>{
        for (final t in state.results)
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

      if (!firstResultShown) {
        firstResultShown = true;
        // Первый источник ответил — показываем результаты и убираем
        // индикатор загрузки. Остальные придут позже и доклеятся.
        state = state.copyWith(results: mergedWithArt, loading: false);
      } else {
        // Последующие источники доклеиваются к уже показанным.
        state = state.copyWith(results: mergedWithArt);
      }

      // Запускаем обогащение обложками для треков этого источника.
      _enrichArtworks(sources[index], list, query, generation);
    }

    // Все источники либо ответили, либо упали по таймауту.
    // Если ни один не ответил до сих пор (все упали мгновенно) —
    // сбрасываем loading и показываем пустой список.
    if (!firstResultShown && !isStale()) {
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
  /// которые это поддерживают (Muzmo, SoundCloud). Для остальных —
  /// no-op.
  void _enrichArtworks(
    dynamic source,
    List<Track> results,
    String query,
    int generation,
  ) {
    // Обогащаем только треки этого источника (важно для режима «all»,
    // где в списке намешаны треки разных источников).
    final sourceTracks =
        results.where((t) => t.sourceId == source.id).toList();
    if (sourceTracks.isEmpty) return;

    if (source is MuzmoSource) {
      source.enrichArtworksInBackground(
        sourceTracks,
        _patchResults(query, generation),
      );
    } else if (source is SoundCloudSource) {
      source.enrichArtworksInBackground(
        sourceTracks,
        _patchResults(query, generation),
      );
    }
  }

  /// Возвращает колбэк, который вклеивает обновлённые треки обратно в
  /// общий список результатов по globalId, игнорируя устаревший поиск.
  ///
  /// [generation] — поколение поиска, при смене которого патч
  /// отбрасывается. Это защищает от ситуации, когда пользователь быстро
  /// сменил фильтр, но query остался прежним.
  void Function(List<Track>) _patchResults(String query, int generation) {
    return (updated) {
      // Игнорируем колбэки от устаревшего поиска.
      if (_searchGeneration != generation || state.query != query) return;
      // Вклеиваем обновлённые треки обратно в общий список по globalId,
      // сохраняя исходный порядок (важно для режима «all»).
      final byId = {for (final t in updated) t.globalId: t};
      final patched = [
        for (final t in state.results) byId[t.globalId] ?? t,
      ];
      state = state.copyWith(results: patched);
    };
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
  try {
    await PlaylistRepository.instance.ensureLoaded();
  } catch (e) {
    // Перевыбрасываем ошибку, чтобы Riverpod перевёл AsyncValue в AsyncError.
    // UI должен обрабатывать это состояние (см. HomePage).
    throw PlaylistLoadException('Failed to load playlists: $e');
  }
  yield PlaylistRepository.instance.current;
  yield* PlaylistRepository.instance.stream;
});

/// Ошибка загрузки плейлистов.
class PlaylistLoadException implements Exception {
  const PlaylistLoadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ошибка загрузки истории.
class HistoryLoadException implements Exception {
  const HistoryLoadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Удобный доступ к репозиторию из UI: для мутаций.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository.instance;
});

/// Поток истории прослушивания (новые сверху). UI слушает через
/// `ref.watch(listenHistoryProvider)` и получает `AsyncValue<List<HistoryEntry>>`.
final listenHistoryProvider = StreamProvider<List<HistoryEntry>>((ref) async* {
  try {
    await HistoryRepository.instance.ensureLoaded();
  } catch (e) {
    throw HistoryLoadException('Failed to load history: $e');
  }
  yield HistoryRepository.instance.current;
  yield* HistoryRepository.instance.stream;
});

/// Удобный доступ к репозиторию истории: для мутаций.
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  return HistoryRepository.instance;
});

/// Лимит записей истории прослушивания. Persist живёт внутри
/// [HistoryRepository] (ключ `history_limit_v1`), максимум —
/// [HistoryRepository.maxLimit].
final historyLimitProvider = StateNotifierProvider<HistoryLimitNotifier, int>(
  (ref) => HistoryLimitNotifier(),
);

class HistoryLimitNotifier extends StateNotifier<int> {
  HistoryLimitNotifier() : super(HistoryRepository.defaultLimit) {
    _load();
  }

  Future<void> _load() async {
    await HistoryRepository.instance.ensureLoaded();
    state = HistoryRepository.instance.limit;
  }

  Future<void> setLimit(int value) async {
    await HistoryRepository.instance.setLimit(value);
    state = HistoryRepository.instance.limit;
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}


final vibrationEnabledProvider = StateNotifierProvider<VibrationNotifier, bool>(
  (ref) => VibrationNotifier(),
);

class VibrationNotifier extends StateNotifier<bool> {
  static const _key = 'vibration_enabled';

  VibrationNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final raw = await AppDatabase.instance.getSetting(_key);
    state = raw != null
        ? (raw == 'true' || raw == '1')
        : true;
  }

  Future<void> setEnabled(bool enabled) async {
    await AppDatabase.instance.setSetting(_key, enabled.toString());
    state = enabled;
  }

  Future<void> toggle() => setEnabled(!state);

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}

enum SearchViewMode { grid, list }

final searchViewModeProvider = StateNotifierProvider<SearchViewModeNotifier, SearchViewMode>(
  (ref) => SearchViewModeNotifier(),
);

class SearchViewModeNotifier extends StateNotifier<SearchViewMode> {
  static const _key = 'search_view_mode';

  SearchViewModeNotifier() : super(SearchViewMode.grid) {
    _load();
  }

  Future<void> _load() async {
    final saved = await AppDatabase.instance.getSetting(_key);
    if (saved != null) {
      state = SearchViewMode.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => SearchViewMode.grid,
      );
    }
  }

  Future<void> setMode(SearchViewMode mode) async {
    await AppDatabase.instance.setSetting(_key, mode.name);
    state = mode;
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}

/// История поисковых запросов (новые сверху). Хранится в SQLite,
/// дедупликация без учёта регистра, максимум [_maxItems] записей.
final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>(
  (ref) => SearchHistoryNotifier(),
);

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  static const _maxItems = 12;

  SearchHistoryNotifier() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await AppDatabase.instance.getSearchHistory(_maxItems);
  }

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    // Дедуплицируем в памяти
    state = [
      q,
      ...state.where((e) => e.toLowerCase() != q.toLowerCase()),
    ].take(_maxItems).toList();
    // Атомарная запись одной строки + чистка лишних
    await AppDatabase.instance.addSearchQuery(q);
    await AppDatabase.instance.trimSearchHistory(_maxItems);
  }

  Future<void> remove(String query) async {
    state = state.where((e) => e != query).toList();
    await AppDatabase.instance.removeSearchQuery(query);
  }

  Future<void> clear() async {
    state = const [];
    await AppDatabase.instance.clearSearchHistory();
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}
