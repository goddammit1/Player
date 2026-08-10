import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/app_database.dart';
import 'package:player/core/history_repository.dart';
import 'package:player/core/playlist_repository.dart';
import 'package:player/models/track.dart';

import '../setup/test_harness.dart';

Track _t(String id) => Track(
      id: id,
      sourceId: 'youtube',
      title: 'Song $id',
      artist: 'Artist $id',
    );

void main() {
  TestHarness.ensureInitialized();

  setUp(() async {
    await TestHarness.setUpDb();
    await PlaylistRepository.instance.resetForTesting();
    await HistoryRepository.instance.reload();
  });

  tearDown(() async {
    await TestHarness.tearDownDb();
  });

  group('FullBackup integration', () {
    test('export contains all tables', () async {
      // Наполняем данными
      await PlaylistRepository.instance.ensureLoaded();
      final pl = PlaylistRepository.instance.create('Test List');
      PlaylistRepository.instance.addTrack(pl.id, _t('t1'));
      PlaylistRepository.instance.addTrack(pl.id, _t('t2'));
      await PlaylistRepository.instance.flush();

      await HistoryRepository.instance.add(_t('h1'));
      await AppDatabase.instance.setSetting('theme', 'dark');
      await AppDatabase.instance.addSearchQuery('hello');

      final json = await AppDatabase.instance.exportFullBackup();

      expect(json, contains('"format":"player_full_backup"'));
      expect(json, contains('"version":2'));
      expect(json, contains('"playlists"'));
      expect(json, contains('"playlist_tracks"'));
      expect(json, contains('"listen_history"'));
      expect(json, contains('"search_history"'));
      expect(json, contains('"settings"'));
      expect(json, contains('"playback_state"'));
    });

    test('importFullBackup restores all data including playback_state', () async {
      // Создаём данные
      await PlaylistRepository.instance.ensureLoaded();
      final pl = PlaylistRepository.instance.create('Rock');
      PlaylistRepository.instance.addTrack(pl.id, _t('r1'));
      await PlaylistRepository.instance.flush();

      await HistoryRepository.instance.add(_t('h1'));
      await AppDatabase.instance.setSetting('theme', 'dark');
      await AppDatabase.instance.addSearchQuery('query1');

      // Сохраняем playback session
      await AppDatabase.instance.savePlaybackSession(
        queueRows: [_t('q1').toMap()],
        currentIndex: 0,
        positionMs: 5000,
      );

      // Экспортируем
      final json = await AppDatabase.instance.exportFullBackup();

      // Закрываем и пересоздаём БД
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();

      // Импортируем
      await AppDatabase.instance.importFullBackup(json);

      // Проверяем плейлисты
      final playlists = await AppDatabase.instance.loadPlaylists();
      expect(playlists.length, 1);
      expect(playlists.first.name, 'Rock');
      expect(playlists.first.tracks.length, 1);
      expect(playlists.first.tracks.first.id, 'r1');

      // Проверяем историю
      final history = await AppDatabase.instance.loadListenHistory(100);
      expect(history.length, 1);
      expect(history.first.track.id, 'h1');

      // Проверяем search history
      final search = await AppDatabase.instance.getSearchHistory(10);
      expect(search.length, 1);
      expect(search.first, 'query1');

      // Проверяем settings
      expect(await AppDatabase.instance.getSetting('theme'), 'dark');

      // Проверяем playback_state
      final session = await AppDatabase.instance.loadPlaybackSession();
      expect(session, isNotNull);
      expect(session!.queue.length, 1);
      expect(session.queue.first.id, 'q1');
      expect(session.positionMs, 5000);
    });

    test('v1 backup without playback_state imports cleanly', () async {
      const v1Json = '{"format":"player_full_backup","version":1,'
          '"exported_at_ms":1,"playlists":[],"playlist_tracks":[],'
          '"playlist_covers":[],"listen_history":[],'
          '"search_history":[],"settings":[]}';

      await AppDatabase.instance.importFullBackup(v1Json);

      expect(await AppDatabase.instance.loadPlaylists(), isEmpty);
      expect(await AppDatabase.instance.loadListenHistory(100), isEmpty);
      expect(await AppDatabase.instance.getSearchHistory(10), isEmpty);

      // playback_state должен быть null (не было в v1)
      expect(await AppDatabase.instance.loadPlaybackSession(), isNull);
    });

    test('import then reload PlaylistRepository', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final pl = PlaylistRepository.instance.create('Imported');
      PlaylistRepository.instance.addTrack(pl.id, _t('imp1'));
      await PlaylistRepository.instance.flush();

      final json = await AppDatabase.instance.exportFullBackup();
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();
      await AppDatabase.instance.importFullBackup(json);

      // PlaylistRepository всё ещё в памяти старый — делаем reload
      await PlaylistRepository.instance.reload();

      final current = PlaylistRepository.instance.current;
      expect(current.length, 1);
      expect(current.first.name, 'Imported');
      expect(current.first.tracks.length, 1);
    });

    test('import then reload HistoryRepository', () async {
      await HistoryRepository.instance.add(_t('imp_h1'));

      final json = await AppDatabase.instance.exportFullBackup();
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();
      await AppDatabase.instance.importFullBackup(json);

      await HistoryRepository.instance.reload();

      final current = HistoryRepository.instance.current;
      expect(current.length, 1);
      expect(current.first.track.id, 'imp_h1');
    });
  });
}