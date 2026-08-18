import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player/core/app_database.dart';
import 'package:player/core/artwork_helper.dart';
import 'package:player/core/history_repository.dart';
import 'package:player/core/playlist_repository.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';

import '../setup/test_harness.dart';

/// Регрессионный тест: после «Clear all cache» трек, у которого была
/// кастомная обложка, должен снова получить ОРИГИНАЛЬНУЮ обложку
/// (из источника/провайдера), а не остаться с мёртвым локальным путём
/// `/custom_artworks/<id>.jpg` в БД.
///
/// Сценарий:
/// 1. Трек в плейлисте имеет originalUrl, но пользователь поставил кастомную
///    обложку — `artworkUrl` в БД перезаписан локальным путём
///    (так делает `PlayerService.updateCustomArtwork`).
/// 2. Пользователь жмёт «Clear all cache»: файлы кастомных обложек удалены,
///    RAM-кэш ArtworkHelper сброшен, SQLite-ключи custom_art_v* удалены.
/// 3. `PlaylistRepository.resetAllTrackArtworks()` / `HistoryRepository...`
///    должны обнулить мёртвый локальный путь, чтобы фоновое обогащение
///    перезапросило оригинал.
///
/// Без фикса шаг 3 оставляет `/custom_artworks/...` в `artworkUrl`
/// (isProviderArtworkUrl=false → путь не сбрасывается, enrichment его
/// не перезапрашивает) — тест падает.
void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  late Directory audioDir;
  late Directory artworkDir;
  late Directory docsDir;

  setUp(() async {
    await TestHarness.setUpDb();
    await PlaylistRepository.instance.resetForTesting();
    await HistoryRepository.instance.resetForTesting();
    await PlaylistRepository.instance.ensureLoaded();
    await HistoryRepository.instance.ensureLoaded();

    ArtworkHelper.resetInit();
    ArtworkProvider.instance.clearMemCache();

    tempDir = Directory.systemTemp.createTempSync('clear_all_regression_');
    audioDir = Directory(p.join(tempDir.path, 'audio'));
    audioDir.createSync(recursive: true);
    artworkDir = Directory(p.join(tempDir.path, 'artwork'));
    artworkDir.createSync(recursive: true);
    docsDir = Directory(p.join(tempDir.path, 'docs'));
    docsDir.createSync(recursive: true);

    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(audioDir);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(artworkDir);
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(docsDir);
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(null);
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(null);
    await TestHarness.tearDownDb();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'после clearAllCache трек с кастомной обложкой получает оригинальную '
    'обложку обратно (мёртвый локальный путь не остаётся в БД)',
    () async {
      const originalUrl = 'https://i.ytimg.com/vi/abc123/hqdefault.jpg';
      const trackId = 'abc123';
      final track = Track(
        id: trackId,
        sourceId: 'youtube',
        title: 'Song',
        artist: 'Artist',
        artworkUrl: originalUrl,
      );

      // 1. Трек в плейлисте и истории.
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.addTrack(p.id, track);
      await HistoryRepository.instance.add(track);
      await PlaylistRepository.instance.flush();

      // 2. Пользователь ставит кастомную обложку: локальный файл + путь
      //    перезаписывает artworkUrl (так делает updateCustomArtwork).
      final customDir = Directory('${docsDir.path}/custom_artworks');
      customDir.createSync(recursive: true);
      final customFile = File('${customDir.path}/$trackId.jpg');
      await customFile.writeAsString('custom');
      final customPath = customDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('$trackId.jpg'))
          .path;
      await AppDatabase.instance.setCustomArtworkPath(trackId, customPath);
      ArtworkHelper.resetInit();
      await ArtworkHelper.init();
      expect(ArtworkHelper.getCustomArtworkSync(trackId), customPath);
      await PlaylistRepository.instance.updateTrackArtwork(
        track.globalId,
        customPath,
      );
      await HistoryRepository.instance.updateTrackArtwork(
        track.globalId,
        customPath,
      );
      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        customPath,
      );
      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        customPath,
      );

      // 3. «Clear all cache»: файлы + RAM + SQLite кастомных обложек удалены.
      await YoutubeCache.instance.clearAllCache();
      expect(await customFile.exists(), false);
      expect(ArtworkHelper.getCustomArtworkSync(trackId), isNull);

      // 4. Сброс artworkUrl в плейлистах/истории (делает cache_page).
      //    Сид кэша провайдера ДО сброса — enrichment восстановит оригинал
      //    мгновенно, без сети.
      ArtworkProvider.instance.cacheArtworkForTesting(
        'Artist',
        'Song',
        originalUrl,
      );
      PlaylistRepository.instance.resetAllTrackArtworks();
      HistoryRepository.instance.resetAllTrackArtworks();

      // Мёртвый локальный путь обнулён сразу после сброса.
      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        isNull,
        reason: 'мёртвый путь кастомной обложки должен быть сброшен',
      );
      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        isNull,
        reason: 'мёртвый путь кастомной обложки должен быть сброшен',
      );

      // 5. Фоновое обогащение перезапрашивает и возвращает оригинал.
      await PlaylistRepository.instance.flushEnrichmentForTesting();
      await HistoryRepository.instance.flushEnrichmentForTesting();

      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        originalUrl,
        reason: 'оригинальная обложка восстановлена в плейлисте',
      );
      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        originalUrl,
        reason: 'оригинальная обложка восстановлена в истории',
      );
    },
  );

  test(
    'resetAllTrackArtworks НЕ сбрасывает живую кастомную обложку '
    '(ветка «Clear artwork cache», файл на диске есть)',
    () async {
      const trackId = 'live1';
      final track = Track(
        id: trackId,
        sourceId: 'youtube',
        title: 'Live',
        artist: 'ArtistLive',
        artworkUrl: 'https://i.ytimg.com/vi/live1/hqdefault.jpg',
      );
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.addTrack(p.id, track);
      await PlaylistRepository.instance.flush();

      // Живая кастомная обложка: файл есть + путь в RAM-кэше ArtworkHelper.
      final customDir = Directory('${docsDir.path}/custom_artworks');
      customDir.createSync(recursive: true);
      final customFile = File('${customDir.path}/$trackId.jpg');
      await customFile.writeAsString('custom-live');
      final customPath = customDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('$trackId.jpg'))
          .path;
      await AppDatabase.instance.setCustomArtworkPath(trackId, customPath);
      ArtworkHelper.resetInit();
      await ArtworkHelper.init();
      expect(ArtworkHelper.getCustomArtworkSync(trackId), customPath);
      await PlaylistRepository.instance.updateTrackArtwork(
        track.globalId,
        customPath,
      );

      // «Clear artwork cache» — кастомные файлы НЕ удаляются, только
      // сброс artworkUrl. Живая кастомная обложка должна сохраниться.
      PlaylistRepository.instance.resetAllTrackArtworks();

      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        customPath,
        reason: 'живая кастомная обложка не сбрасывается',
      );

      await PlaylistRepository.instance.flushEnrichmentForTesting();
      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        customPath,
      );
    },
  );
}
