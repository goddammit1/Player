// Прямые юнит-тесты доменных DAO (lib/core/database/*.dart).
//
// DAO выделены из монолита AppDatabase в Фазе 1; AppDatabase делегирует
// им запросы, поэтому косвенно они покрываются app_database_test.dart.
// Здесь добавляем точечное прямое покрытие двух ключевых DAO без сети:
// SearchHistoryDao (история поиска) и SettingsDao (key-value настройки).
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/database/search_history_dao.dart';
import 'package:player/core/database/settings_dao.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();
  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('SearchHistoryDao', () {
    test('getSearchHistory returns newest first with limit', () async {
      final db = await AppDatabase.instance.database;
      await SearchHistoryDao.instance.addSearchQuery(db, 'first');
      await SearchHistoryDao.instance.addSearchQuery(db, 'second');
      await SearchHistoryDao.instance.addSearchQuery(db, 'third');
      final top2 = await SearchHistoryDao.instance.getSearchHistory(db, 2);
      expect(top2.length, 2);
      expect(top2.first, 'third');
    });

    test('addSearchQuery deduplicates case-insensitively (SQL delete)', () async {
      final db = await AppDatabase.instance.database;
      await SearchHistoryDao.instance.addSearchQuery(db, 'Hello');
      await SearchHistoryDao.instance.addSearchQuery(db, 'hello');
      final all = await SearchHistoryDao.instance.getSearchHistory(db, 20);
      expect(all.length, 1);
      expect(all.first, 'hello');
    });

    test('setSearchHistory replaces state with limit + descending timestamps',
        () async {
      final db = await AppDatabase.instance.database;
      await SearchHistoryDao.instance.setSearchHistory(
          db, ['a', 'b', 'c', 'd'], 2);
      final all = await SearchHistoryDao.instance.getSearchHistory(db, 20);
      expect(all.length, 2);
      expect(all.first, 'a');
    });

    test('removeSearchQuery deletes exact query', () async {
      final db = await AppDatabase.instance.database;
      await SearchHistoryDao.instance.addSearchQuery(db, 'keep');
      await SearchHistoryDao.instance.addSearchQuery(db, 'drop');
      await SearchHistoryDao.instance.removeSearchQuery(db, 'drop');
      final all = await SearchHistoryDao.instance.getSearchHistory(db, 20);
      expect(all.length, 1);
      expect(all.first, 'keep');
    });

    test('clearSearchHistory removes all rows', () async {
      final db = await AppDatabase.instance.database;
      await SearchHistoryDao.instance.addSearchQuery(db, 'q');
      await SearchHistoryDao.instance.clearSearchHistory(db);
      expect(await SearchHistoryDao.instance.getSearchHistory(db, 10),
          isEmpty);
    });
  });

  group('SettingsDao', () {
    test('getSetting returns null for missing key', () async {
      final db = await AppDatabase.instance.database;
      expect(await SettingsDao.instance.getSetting(db, 'missing'), isNull);
    });

    test('setSetting / getSetting roundtrip', () async {
      final db = await AppDatabase.instance.database;
      await SettingsDao.instance.setSetting(db, 'theme', 'dark');
      expect(await SettingsDao.instance.getSetting(db, 'theme'), 'dark');
    });

    test('setSetting overwrites via replace conflict', () async {
      final db = await AppDatabase.instance.database;
      await SettingsDao.instance.setSetting(db, 'k', 'v1');
      await SettingsDao.instance.setSetting(db, 'k', 'v2');
      expect(await SettingsDao.instance.getSetting(db, 'k'), 'v2');
    });

    test('removeSetting deletes', () async {
      final db = await AppDatabase.instance.database;
      await SettingsDao.instance.setSetting(db, 'k', 'v');
      await SettingsDao.instance.removeSetting(db, 'k');
      expect(await SettingsDao.instance.getSetting(db, 'k'), isNull);
    });

    test('getAllSettings returns map', () async {
      final db = await AppDatabase.instance.database;
      await SettingsDao.instance.setSetting(db, 'a', '1');
      await SettingsDao.instance.setSetting(db, 'b', '2');
      final all = await SettingsDao.instance.getAllSettings(db);
      expect(all['a'], '1');
      expect(all['b'], '2');
    });

    test('clearArtworkCacheDb removes only artwork_v3_* keys', () async {
      final db = await AppDatabase.instance.database;
      await SettingsDao.instance.setSetting(db, 'artwork_v3_artist_title', 'u1');
      await SettingsDao.instance.setSetting(db, 'theme', 'dark');
      await SettingsDao.instance.clearArtworkCacheDb(db);
      expect(await SettingsDao.instance.getSetting(db, 'theme'), 'dark');
      expect(await SettingsDao.instance.getSetting(
          db, 'artwork_v3_artist_title'), isNull);
    });
  });
}