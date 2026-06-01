import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/track.dart';
import '../sources/muzmo_source.dart';
import '../sources/source_registry.dart';
import 'player_service.dart';

/// PlayerService инициализируется в main.dart и пробрасывается сюда через
/// override. См. main.dart -> ProviderScope(overrides: [...]).
final playerServiceProvider = Provider<PlayerService>((ref) {
  throw UnimplementedError('Override in ProviderScope');
});

/// Стейт текущего поиска.
class SearchState {
  final String query;
  final List<Track> results;
  final bool loading;
  final String? error;

  const SearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.error,
  });

  SearchState copyWith({
    String? query,
    List<Track>? results,
    bool? loading,
    String? error,
  }) => SearchState(
    query: query ?? this.query,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    error: error,
  );
}

class SearchController extends StateNotifier<SearchState> {
  SearchController() : super(const SearchState());

  /// Текущий выбранный источник. Меняется через [setSourceId] и
  /// автоматически используется в [search] / [refresh].
  String _sourceId = 'muzmo';
  String get sourceId => _sourceId;

  void setSourceId(String id) {
    if (_sourceId == id) return;
    _sourceId = id;
    // Если был активный запрос — перепоиск в новом источнике, чтобы
    // пользователь сразу видел релевантные результаты.
    if (state.query.trim().isNotEmpty) {
      search(state.query);
    }
  }

  Future<void> search(String query, {String? sourceId}) async {
    if (query.trim().isEmpty) {
      state = const SearchState();
      return;
    }
    final useSource = sourceId ?? _sourceId;
    state = state.copyWith(query: query, loading: true, error: null);
    final myQuery = query;
    try {
      final source = SourceRegistry.instance.require(useSource);
      final results = await source.search(query);
      // Перед публикацией результатов убеждаемся, что пользователь не
      // успел ввести новый запрос или сменить источник.
      if (state.query != myQuery || _sourceId != useSource) return;
      state = state.copyWith(results: results, loading: false);

      // Для Muzmo обогащаем обложками асинхронно: треки уже видны,
      // обложки доезжают волной по мере получения от Genius/iTunes.
      if (source is MuzmoSource) {
        source.enrichArtworksInBackground(results, (updated) {
          // Игнорируем колбэки от устаревшего поиска.
          if (state.query != myQuery || _sourceId != useSource) return;
          state = state.copyWith(results: updated);
        });
      }
    } catch (e) {
      if (state.query != myQuery) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }
}

final searchProvider = StateNotifierProvider<SearchController, SearchState>((
  ref,
) {
  return SearchController();
});
