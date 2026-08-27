// Прямые юнит-тесты доменных DAO (lib/core/database/*.dart).
//
// DAO выделены из монолита AppDatabase в Фазе 1; AppDatabase делегирует
// им запросы, поэтому косвенно они покрываются app_database_test.dart.
// Здесь добавляем точечное прямое покрытие двух ключевых DAO без сети:
// SearchHistoryDao (история поиска) и SettingsDao (key-value настройки).
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/database/playlist_dao.dart';
import 'package:player/core/database/search_history_dao.dart';
import 'package:player/core/database/settings_dao.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
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

  group('PlaylistDao - manual (saved) track order', () {
    const t1 = Track(id: 'a', sourceId: 'youtube', title: 'Alpha', artist: 'A');
    const t2 = Track(id: 'b', sourceId: 'youtube', title: 'Beta', artist: 'B');
    const t3 = Track(id: 'c', sourceId: 'youtube', title: 'Gamma', artist: 'C');

    test('saveAllPlaylists persists track order and loadPlaylists restores it',
        () async {
      final db = await AppDatabase.instance.database;

      final p = Playlist(
        id: 'pl1',
        name: 'Manual Order',
        tracks: const [t1, t2, t3],
        createdAt: DateTime(2024, 1, 1),
      );
      await PlaylistDao.instance.saveAllPlaylists(db, [p]);

      final loaded = await PlaylistDao.instance.loadPlaylists(db);
      expect(loaded.single.tracks.map((t) => t.id).toList(), ['a', 'b', 'c']);
    });

    test('reordering the list then re-saving changes the loaded order',
        () async {
      final db = await AppDatabase.instance.database;
      final p = Playlist(
        id: 'pl2',
        name: 'Reorder',
        tracks: const [t1, t2, t3],
        createdAt: DateTime(2024, 1, 1),
      );
      await PlaylistDao.instance.saveAllPlaylists(db, [p]);

      // Имитируем перестановку, как делает PlaylistRepository.reorderTracks:
      // треки «переезжают» — последний становится первым.
      final reordered = p.copyWith(tracks: const [t3, t1, t2]);
      await PlaylistDao.instance.saveAllPlaylists(db, [reordered]);

      final loaded = await PlaylistDao.instance.loadPlaylists(db);
      expect(
        loaded.single.tracks.map((t) => t.id).toList(),
        ['c', 'a', 'b'],
      );
    });
  });
}