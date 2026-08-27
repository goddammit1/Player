// Тесты PlaylistSortModeNotifier — режима сортировки треков внутри плейлиста.
//
// Покрывают ключевое поведение фичи «manual-режим сортировки»:
//   1. значение по умолчанию — date;
//   2. setMode персистит выбор в таблицу settings и обновляет state;
//   3. сохранённое значение восстанавливается при (пере)создании
//      нотифаера — это связывает выбор в UI с БД, делая выбор режима
//      (включая manual) устойчивым к перезапуску приложения.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/database/app_database.dart';
import 'package:player/core/providers.dart';

import '../setup/test_harness.dart';

/// Ждёт завершения асинхронной инициализации нотифаера через его
/// `@visibleForTesting ready` Future (аналог `_readyNotifier` из
/// test/state/providers_test.dart).
Future<T> _readyNotifier<T extends StateNotifier>(T notifier) async {
  // ignore: invalid_use_of_visible_for_testing_member
  await (notifier as dynamic).ready;
  return notifier;
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('PlaylistSortModeNotifier', () {
    test('defaults to date', () async {
      final notifier = await _readyNotifier(PlaylistSortModeNotifier());
      expect(notifier.state, PlaylistSortMode.date);
    });

    test('setMode updates state and persists to settings', () async {
      final notifier = await _readyNotifier(PlaylistSortModeNotifier());

      await notifier.setMode(PlaylistSortMode.manual);

      expect(notifier.state, PlaylistSortMode.manual);
      expect(
        await AppDatabase.instance.getSetting(playlistSortModeSettingKey),
        'manual',
      );
    });

    test('saved manual mode is restored on a fresh notifier', () async {
      // Записываем выбор «manual» напрямую в БД, как будто пользователь
      // выбрал его в прошлой сессии.
      await AppDatabase.instance.setSetting(
        playlistSortModeSettingKey,
        'manual',
      );

      final fresh = await _readyNotifier(PlaylistSortModeNotifier());
      expect(fresh.state, PlaylistSortMode.manual);
    });

    test('reload re-reads persisted value', () async {
      final notifier = await _readyNotifier(PlaylistSortModeNotifier());
      expect(notifier.state, PlaylistSortMode.date);

      await AppDatabase.instance.setSetting(
        playlistSortModeSettingKey,
        'title',
      );
      await notifier.reload();

      expect(notifier.state, PlaylistSortMode.title);
    });
  });
}