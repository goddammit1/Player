import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/app_database.dart';
import 'package:player/core/history_repository.dart';
import 'package:player/models/track.dart';
import 'package:player/models/playlist.dart';
import 'package:sqflite/sqflite.dart';
import '../setup/test_harness.dart';

Track _testTrack(String id) => Track(
      id: id, sourceId: 'youtube', title: 'Song $id', artist: 'Artist $id',
      duration: const Duration(seconds: 180),
      artworkUrl: 'https://img.example.com/$id.jpg',
      qualityScore: 80, qualityLabel: 'HD',
      extra: {'streamUrl': 'https://stream.example.com/$id'},
    );

HistoryEntry _testEntry(String id) =>
    HistoryEntry(track: _testTrack(id),
        playedAt: DateTime(2025, 1, 1 + id.hashCode.abs() % 28));

Playlist _makePlaylist(String id, String name, int trackCount) {
  return Playlist(
    id: id, name: name,
    tracks: List.generate(trackCount, (i) => _testTrack('${id}_$i')),
    createdAt: DateTime(2024, 1, 1 + trackCount),
  );
}

void main() {
  TestHarness.ensureInitialized();
  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('AppDatabase - Settings', () {
    test('getSetting returns null for missing key', () async {
      expect(await AppDatabase.instance.getSetting('nonexistent'), isNull);
    });
    test('setSetting / getSetting roundtrip', () async {
      await AppDatabase.instance.setSetting('k', 'v');
      expect(await AppDatabase.instance.getSetting('k'), 'v');
    });
    test('setSetting overwrites', () async {
      await AppDatabase.instance.setSetting('k', 'v1');
      await AppDatabase.instance.setSetting('k', 'v2');
      expect(await AppDatabase.instance.getSetting('k'), 'v2');
    });
    test('removeSetting', () async {
      await AppDatabase.instance.setSetting('k', 'v');
      await AppDatabase.instance.removeSetting('k');
      expect(await AppDatabase.instance.getSetting('k'), isNull);
    });
  });

  group('AppDatabase - Custom artwork', () {
    test('set/get', () async {
      await AppDatabase.instance.setCustomArtworkPath('t1', '/p.jpg');
      expect(await AppDatabase.instance.getCustomArtworkPath('t1'), '/p.jpg');
    });
    test('missing null', () async {
      expect(await AppDatabase.instance.getCustomArtworkPath('nope'), isNull);
    });
    test('remove', () async {
      await AppDatabase.instance.setCustomArtworkPath('t1', '/p.jpg');
      await AppDatabase.instance.removeCustomArtworkPath('t1');
      expect(await AppDatabase.instance.getCustomArtworkPath('t1'), isNull);
    });
  });

  group('AppDatabase - Search history', () {
    test('add / get', () async {
      await AppDatabase.instance.addSearchQuery('q1');
      await AppDatabase.instance.addSearchQuery('q2');
      final h = await AppDatabase.instance.getSearchHistory(10);
      expect(h.length, 2); expect(h.first, 'q2');
    });
    test('dedup', () async {
      await AppDatabase.instance.addSearchQuery('q');
      await AppDatabase.instance.addSearchQuery('q');
      expect((await AppDatabase.instance.getSearchHistory(10)).length, 1);
    });
    test('remove', () async {
      await AppDatabase.instance.addSearchQuery('q1');
      await AppDatabase.instance.addSearchQuery('q2');
      await AppDatabase.instance.removeSearchQuery('q1');
      final h = await AppDatabase.instance.getSearchHistory(10);
      expect(h.length, 1); expect(h.first, 'q2');
    });
    test('clear', () async {
      await AppDatabase.instance.addSearchQuery('q1');
      await AppDatabase.instance.clearSearchHistory();
      expect(await AppDatabase.instance.getSearchHistory(10), isEmpty);
    });
    test('trim', () async {
      for (final q in ['a', 'b', 'c']) {
        await AppDatabase.instance.addSearchQuery(q);
      }
      await AppDatabase.instance.trimSearchHistory(2);
      expect((await AppDatabase.instance.getSearchHistory(10)).length, 2);
    });
  });

  group('AppDatabase - Playlists', () {
    test('empty roundtrip', () async {
      await AppDatabase.instance.saveAllPlaylists([]);
      expect(await AppDatabase.instance.loadPlaylists(), isEmpty);
    });
    test('single roundtrip', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('p1', 'Rock', 3)]);
      final l = await AppDatabase.instance.loadPlaylists();
      expect(l.length, 1); expect(l.first.name, 'Rock');
      expect(l.first.tracks.length, 3);
    });
    test('multiple', () async {
      await AppDatabase.instance.saveAllPlaylists([
        _makePlaylist('p1', 'Rock', 2), _makePlaylist('p2', 'Jazz', 1)]);
      expect((await AppDatabase.instance.loadPlaylists()).length, 2);
    });
    test('idempotent', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('p1', 'Rock', 2)]);
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('p1', 'Metal', 1)]);
      final l = await AppDatabase.instance.loadPlaylists();
      expect(l.length, 1); expect(l.first.name, 'Metal');
    });
    test('quality', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('pq', 'Q', 1)]);
      final t = (await AppDatabase.instance.loadPlaylists()).first.tracks.first;
      expect(t.qualityScore, 80); expect(t.qualityLabel, 'HD');
    });
    test('extra', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('pe', 'E', 1)]);
      final t = (await AppDatabase.instance.loadPlaylists()).first.tracks.first;
      expect(t.extra['streamUrl'], isNotNull);
    });
    test('delete', () async {
      await AppDatabase.instance.saveAllPlaylists([
        _makePlaylist('p1', 'A', 1), _makePlaylist('p2', 'B', 1)]);
      await AppDatabase.instance.deletePlaylist('p1');
      final l = await AppDatabase.instance.loadPlaylists();
      expect(l.length, 1); expect(l.first.id, 'p2');
    });
    test('clear', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('p1', 'A', 1)]);
      await AppDatabase.instance.clearPlaylists();
      expect(await AppDatabase.instance.loadPlaylists(), isEmpty);
    });
    test('sort_order', () async {
      final pl = Playlist(id: 'ps', name: 'S', createdAt: DateTime.now(),
        tracks: [_testTrack('3'), _testTrack('1'), _testTrack('2')]);
      await AppDatabase.instance.saveAllPlaylists([pl]);
      final ids = (await AppDatabase.instance.loadPlaylists())
          .first.tracks.map((t) => t.id).toList();
      expect(ids, ['3', '1', '2']);
    });
  });

  group('AppDatabase - Listen history', () {
    test('add/load', () async {
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('1'), playedAt: DateTime(2025)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('2'), playedAt: DateTime(2026)));
      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.length, 2); expect(h.first.track.id, '2');
    });
    test('dedup', () async {
      await AppDatabase.instance.addListenHistoryEntry(_testEntry('1'));
      final newer = HistoryEntry(
        track: _testTrack('1'),
        playedAt: DateTime(2026, 6, 1),
      );
      await AppDatabase.instance.addListenHistoryEntry(newer);
      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.length, 1);
      expect(h.first.playedAt, DateTime(2026, 6, 1));
    });
    test('remove', () async {
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('1'), playedAt: DateTime(2025)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('2'), playedAt: DateTime(2026)));
      await AppDatabase.instance.removeListenHistoryEntry(
          HistoryEntry(track: _testTrack('1'), playedAt: DateTime(2025)));
      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.length, 1); expect(h.first.track.id, '2');
    });
    test('clear', () async {
      await AppDatabase.instance.addListenHistoryEntry(_testEntry('1'));
      await AppDatabase.instance.clearListenHistory();
      expect(await AppDatabase.instance.loadListenHistory(100), isEmpty);
    });
    test('trim', () async {
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('a'), playedAt: DateTime(2025, 1, 1)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('b'), playedAt: DateTime(2025, 2, 1)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('c'), playedAt: DateTime(2025, 3, 1)));
      await AppDatabase.instance.trimListenHistory(2);
      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.length, 2); expect(h.first.track.id, 'c');
    });
    test('limit param', () async {
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('a'), playedAt: DateTime(2025, 1, 1)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('b'), playedAt: DateTime(2025, 2, 1)));
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('c'), playedAt: DateTime(2025, 3, 1)));
      final h = await AppDatabase.instance.loadListenHistory(1);
      expect(h.length, 1); expect(h.first.track.id, 'c');
    });
    test('updateArtwork', () async {
      await AppDatabase.instance.addListenHistoryEntry(
          HistoryEntry(track: _testTrack('1'), playedAt: DateTime(2025)));
      await AppDatabase.instance
          .updateListenHistoryArtwork('youtube:1', 'https://img.u.jpg');
      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.first.track.artworkUrl, 'https://img.u.jpg');
    });
  });

  group('AppDatabase - Playback session', () {
    test('roundtrip', () async {
      final rows = [_testTrack('10').toMap(), _testTrack('20').toMap(),
          _testTrack('30').toMap()];
      await AppDatabase.instance.savePlaybackSession(
        queueRows: rows, currentIndex: 1, positionMs: 45000);
      final s = await AppDatabase.instance.loadPlaybackSession();
      expect(s, isNotNull);
      expect(s!.queue.length, 3); expect(s.queue[1].id, '20');
      expect(s.currentIndex, 1); expect(s.positionMs, 45000);
    });
    test('overwrites', () async {
      await AppDatabase.instance.savePlaybackSession(
        queueRows: [_testTrack('1').toMap()], currentIndex: 0, positionMs: 0);
      await AppDatabase.instance.savePlaybackSession(
        queueRows: [_testTrack('2').toMap()], currentIndex: 0, positionMs: 5000);
      final s = await AppDatabase.instance.loadPlaybackSession();
      expect(s!.queue.first.id, '2'); expect(s.positionMs, 5000);
    });
    test('null when empty', () async {
      expect(await AppDatabase.instance.loadPlaybackSession(), isNull);
    });
  });

  group('AppDatabase - Full backup', () {
    test('export/import roundtrip', () async {
      await AppDatabase.instance.saveAllPlaylists([_makePlaylist('p1', 'Rock', 2)]);
      await AppDatabase.instance.addListenHistoryEntry(_testEntry('1'));
      await AppDatabase.instance.addSearchQuery('hello');
      await AppDatabase.instance.setSetting('theme', 'dark');
      await AppDatabase.instance.setCustomArtworkPath('t1', '/img.jpg');
      await AppDatabase.instance.savePlaybackSession(
        queueRows: [_testTrack('99').toMap()], currentIndex: 0, positionMs: 12345);

      final json = await AppDatabase.instance.exportFullBackup();
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();
      await AppDatabase.instance.importFullBackup(json);

      final pl = await AppDatabase.instance.loadPlaylists();
      expect(pl.length, 1);
      expect(pl.first.name, 'Rock');
      expect(pl.first.tracks.length, 2);

      final h = await AppDatabase.instance.loadListenHistory(100);
      expect(h.length, 1);
      expect(h.first.track.id, '1');

      final sh = await AppDatabase.instance.getSearchHistory(10);
      expect(sh.length, 1);
      expect(sh.first, 'hello');

      expect(await AppDatabase.instance.getSetting('theme'), 'dark');
      expect(await AppDatabase.instance.getCustomArtworkPath('t1'), '/img.jpg');

      final sess = await AppDatabase.instance.loadPlaybackSession();
      expect(sess, isNotNull);
      expect(sess!.queue.first.id, '99');
      expect(sess.positionMs, 12345);
    });

    test('throws on invalid JSON', () async {
      expect(() => AppDatabase.instance.importFullBackup('no'),
          throwsFormatException);
    });

    test('throws on wrong format', () async {
      expect(() => AppDatabase.instance.importFullBackup('{"format":"x"}'),
          throwsFormatException);
    });

    test('v1 no playback_state', () async {
      await AppDatabase.instance.importFullBackup(
        '{"format":"player_full_backup","version":1,'
        '"exported_at_ms":1,"playlists":[],"playlist_tracks":[],'
        '"playlist_covers":[],"listen_history":[],'
        '"search_history":[],"settings":[]}');
      expect(await AppDatabase.instance.loadPlaylists(), isEmpty);
    });
  });

  group('AppDatabase - Migration v3→v4', () {
    test('v3→v4 clears artwork cache entries', () async {
      // Закрываем текущую БД v4
      await AppDatabase.instance.close();

      // Создаём БД v3 напрямую через sqflite,
      // симулируя состояние до миграции v3→v4
      final dbPath = AppDatabase.testDbPath!;
      final v3db = await openDatabase(
        dbPath,
        version: 3,
        onCreate: (db, version) async {
          // Воссоздаём минимальный набор таблиц (достаточный для теста)
          await db.execute('''CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {},
      );

      // Вставляем тестовые artwork-кэш записи (имитация v3)
      await v3db.insert('settings', {'key': 'artwork_v3_artist1_title1', 'value': 'https://img.example.com/1.jpg'});
      await v3db.insert('settings', {'key': 'artwork_v3_artist2_title2', 'value': ''});  // пустой — тоже должен удалиться
      await v3db.insert('settings', {'key': 'artwork_v3_artist3_title3', 'value': 'https://img.example.com/3.jpg'});
      await v3db.insert('settings', {'key': 'theme', 'value': 'dark'});  // не-artwork ключ — должен остаться
      await v3db.insert('settings', {'key': 'migration_v1_done', 'value': '1'});

      await v3db.close();

      // Теперь открываем БД как v4 — это запустит _onUpgrade v3→v4
      AppDatabase.testDbPath = dbPath;
      // Принудительно закрываем (хотя уже закрыто) и переоткрываем
      await AppDatabase.instance.close();
      final db = await AppDatabase.instance.database;

      // Проверяем: artwork-записи удалены
      final rows = await db.query('settings');
      final keys = rows.map((r) => r['key'] as String).toList();

      expect(keys.contains('artwork_v3_artist1_title1'), false,
          reason: 'artwork_v3_* записи должны быть удалены миграцией v3→v4');
      expect(keys.contains('artwork_v3_artist2_title2'), false);
      expect(keys.contains('artwork_v3_artist3_title3'), false);

      // Не-artwork ключи сохранились
      expect(keys.contains('theme'), true);
      expect(keys.contains('migration_v1_done'), true);
    });
  });
}