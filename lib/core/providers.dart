import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import '../sources/muzmo_source.dart';
import '../sources/soundcloud_source.dart';
import '../sources/source_registry.dart';
import 'player_service.dart';
import 'playlist_repository.dart';
export 'appearance_provider.dart';
export 'dynamic_colors.dart';
export 'global_theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    _enrichArtworks(source, results, query);
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
  Future<void> _searchAll(String query, bool Function() isStale) async {
    final sources = SourceRegistry.instance.searchable;
    if (sources.isEmpty) {
      state = state.copyWith(results: const [], loading: false);
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
      final merged = _interleave(
        List.generate(results.length, (i) => completed[i] ? results[i] : const []),
      );

      if (!firstResultShown) {
        firstResultShown = true;
        // Первый источник ответил — показываем результаты и убираем
        // индикатор загрузки. Остальные придут позже и доклеятся.
        state = state.copyWith(results: merged, loading: false);
      } else {
        // Последующие источники доклеиваются к уже показанным.
        state = state.copyWith(results: merged);
      }

      // Запускаем обогащение обложками для треков этого источника.
      _enrichArtworks(sources[index], list, query);
    }

    // Все источники либо ответили, либо упали по таймауту.
    // Если ни один не ответил до сих пор (все упали мгновенно) —
    // сбрасываем loading и показываем пустой список.
    if (!firstResultShown && !isStale()) {
      state = state.copyWith(results: const [], loading: false);
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

  /// Запускает фоновое обогащение обложками для треков источников,
  /// которые это поддерживают (Muzmo, SoundCloud). Для остальных —
  /// no-op.
  void _enrichArtworks(dynamic source, List<Track> results, String query) {
    // Обогащаем только треки этого источника (важно для режима «all»,
    // где в списке намешаны треки разных источников).
    final sourceTracks =
        results.where((t) => t.sourceId == source.id).toList();
    if (sourceTracks.isEmpty) return;

    if (source is MuzmoSource) {
      source.enrichArtworksInBackground(sourceTracks, _patchResults(query));
    } else if (source is SoundCloudSource) {
      source.enrichArtworksInBackground(sourceTracks, _patchResults(query));
    }
  }

  /// Возвращает колбэк, который вклеивает обновлённые треки обратно в
  /// общий список результатов по globalId, игнорируя устаревший поиск.
  void Function(List<Track>) _patchResults(String query) {
    return (updated) {
      // Игнорируем колбэки от устаревшего поиска.
      if (state.query != query) return;
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
  await PlaylistRepository.instance.ensureLoaded();
  yield PlaylistRepository.instance.current;
  yield* PlaylistRepository.instance.stream;
});

/// Удобный доступ к репозиторию из UI: для мутаций.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository.instance;
});


final vibrationEnabledProvider = StateNotifierProvider<VibrationNotifier, bool>(
  (ref) => VibrationNotifier(),
);

class VibrationNotifier extends StateNotifier<bool> {
  static const _key = 'vibration_enabled';

  VibrationNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
    state = enabled;
  }

  Future<void> toggle() => setEnabled(!state);
}
