// lib/search/search_settings.dart
//
// Настройки поиска, вынесенные из lib/core/providers.dart (Фаза 3.5):
// режим отображения результатов (grid/list) и история поисковых запросов.
//
// Раньше жили в core/providers.dart и тянули AppDatabase-зависимость в общий
// слой провайдеров. Теперь они перенесены рядом с самим поиском (lib/search/).
// Для обратной совместимости lib/core/providers.dart делает
// `export '../search/search_settings.dart'`, поэтому старые импорты
// `core/providers.dart` продолжают работать без правок.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';

/// Режим отображения результатов поиска.
enum SearchViewMode { grid, list }

final searchViewModeProvider = StateNotifierProvider<SearchViewModeNotifier, SearchViewMode>(
  (ref) => SearchViewModeNotifier(),
);

class SearchViewModeNotifier extends StateNotifier<SearchViewMode> {
  static const _key = 'search_view_mode';

  SearchViewModeNotifier() : super(SearchViewMode.grid) {
    _ready = _load();
  }

  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

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
    _ready = _load();
  }

  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

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