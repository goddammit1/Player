// lib/core/providers/playlist_sort_mode.dart
//
// Режим сортировки треков внутри открытого плейлиста.
//
// Раньше выбор жил локально в состоянии PlaylistPage (`_SortMode.date` +
// bool `_sortReversed`) и не сохранялся: после перезапуска приложение
// всегда открывало плейлист с режимом «по дате». Плюс ручной порядок
// (`manual`) был объявлен в enum, но в логике совпадал с `date` — реального
// ручного режима не существовало.
//
// Здесь выбор режима вынесен в StateNotifier-провайдер и персистится
// в таблицу `settings` (SQLite), так что:
//   1. выбор переживает перезапуск приложения;
//   2. UI и слой данных читают один и тот же источник истины;
//   3. `manual` стал самостоятельным значением, которое не трогает
//      сохранённый порядок треков (см. использование в PlaylistPage).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';

/// Режим сортировки треков внутри плейлиста.
///
/// * [date] — «по дате» (порядок хранения из БД / порядок добавления);
/// * [title] — по названию (A→Z);
/// * [artist] — по исполнителю (A→Z);
/// * [manual] — строго ручной порядок: порядок, сохранённый в БД при
///   добавлении/перестановке треков, без дополнительной сортировки
///   и без реверса.
enum PlaylistSortMode implements Comparable<PlaylistSortMode> {
  date('By date'),
  title('By title'),
  artist('By artist'),
  manual('Manual');

  final String label;
  const PlaylistSortMode(this.label);

  @override
  int compareTo(PlaylistSortMode other) => index.compareTo(other.index);
}

/// Ключ в таблице settings, где хранится выбранный режим сортировки.
const String playlistSortModeSettingKey = 'playlist_sort_mode';

/// Провайдер выбранного режима сортировки плейлиста.
/// Значение восстанавливается из БД при первом доступе.
final playlistSortModeProvider =
    StateNotifierProvider<PlaylistSortModeNotifier, PlaylistSortMode>(
  (ref) => PlaylistSortModeNotifier(),
);

class PlaylistSortModeNotifier extends StateNotifier<PlaylistSortMode> {
  /// Значение по умолчанию — «по дате» (поведение приложения до этой фичи).
  PlaylistSortModeNotifier() : super(PlaylistSortMode.date) {
    _ready = _load();
  }

  /// Тестовый конструктор: инициализирует состояние [initial] БЕЗ чтения БД.
  ///
  /// Нужен виджет-тестам PlaylistPage: дефолтный конструктор запускает
  /// асинхронный `_load()`, который лениво обращается к SQLite и может
  /// упасть на уже закрытой tearDown'ом БД (sqflite_ffi) или повиснуть
  /// в FakeAsync-зоне. Здесь `_ready` сразу завершён, а `setMode` в тестах
  /// не вызывается (или перенаправляется на in-memory state).
  @visibleForTesting
  PlaylistSortModeNotifier.seeded(super.initial) {
    _ready = Future<void>.value();
  }

  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  Future<void> _load() async {
    final saved = await AppDatabase.instance.getSetting(
      playlistSortModeSettingKey,
    );
    if (saved != null) {
      state = PlaylistSortMode.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => PlaylistSortMode.date,
      );
    }
  }

  /// Устанавливает и персистит режим сортировки.
  Future<void> setMode(PlaylistSortMode mode) async {
    await AppDatabase.instance.setSetting(
      playlistSortModeSettingKey,
      mode.name,
    );
    state = mode;
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}