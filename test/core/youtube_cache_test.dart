import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player/core/app_database.dart';
import 'package:player/core/artwork_helper.dart';
import 'package:player/core/youtube_cache.dart';

import '../setup/test_harness.dart';

/// Unit-тесты YoutubeCache (cacheIdFor, эвикция, pin/unpin, protected id).
///
/// Все используют тестовые хуки `setAudioDirForTesting` /
/// `setArtworkDirForTesting` / `setDocsDirForTesting` (ArtworkHelper) —
/// работают с реальной файловой системой (temp dir), но без зависимости
/// от path_provider. Группа clearAllCache поднимает БД через TestHarness
/// (sqflite_common_ffi), остальные группы БД не используют.
void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  late Directory audioDir;
  late Directory artworkDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('yt_cache_test_');
    audioDir = Directory(p.join(tempDir.path, 'audio'));
    audioDir.createSync(recursive: true);
    artworkDir = Directory(p.join(tempDir.path, 'artwork'));
    artworkDir.createSync(recursive: true);
    // Подменяем каталоги аудио и обложек, минуя path_provider
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(audioDir);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(artworkDir);
    // Отменяем дебаунс-таймер от предыдущих тестов
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setProtectedId(null);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(null);
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ═════════════════════════════════════════════════════════════════
  //  cacheIdFor
  // ═════════════════════════════════════════════════════════════════

  group('cacheIdFor', () {
    test('muzmo source returns muzmo_ prefix', () {
      expect(
        YoutubeCache.cacheIdFor(sourceId: 'muzmo', trackId: '123'),
        'muzmo_123',
      );
    });

    test('soundcloud source returns soundcloud_ prefix', () {
      expect(
        YoutubeCache.cacheIdFor(sourceId: 'soundcloud', trackId: 'abc'),
        'soundcloud_abc',
      );
    });

    test('unknown source returns trackId as-is', () {
      expect(
        YoutubeCache.cacheIdFor(sourceId: 'youtube', trackId: 'dQw4w'),
        'dQw4w',
      );
      expect(
        YoutubeCache.cacheIdFor(sourceId: 'custom', trackId: 'xyz'),
        'xyz',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  File operations
  // ═════════════════════════════════════════════════════════════════

  group('fileFor / hasFile / findFile', () {
    test('fileFor returns File in audio dir with correct name', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final file = await YoutubeCache.instance.fileFor('test123', extension: 'mp3');
      expect(file.path, contains('audio'));
      expect(p.basename(file.path), 'test123.mp3');
    });

    test('hasFile returns false for missing file', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      expect(await YoutubeCache.instance.hasFile('nonexistent'), false);
    });

    test('hasFile returns true after file is created and touched', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final file = await YoutubeCache.instance.fileFor('existing', extension: 'mp3');
      await file.create(recursive: true);
      // ignore: invalid_use_of_visible_for_testing_member
      expect(await YoutubeCache.instance.hasFile('existing'), true);
    });

    test('findFile finds file with any known extension', () async {
      // Создаём файл с расширением m4a (легаси YouTube)
      final f = File(p.join(audioDir.path, 'legacy.m4a'));
      await f.create(recursive: true);
      // ignore: invalid_use_of_visible_for_testing_member
      final found = await YoutubeCache.instance.findFile('legacy');
      expect(found, isNotNull);
      expect(p.basename(found!.path), 'legacy.m4a');
    });

    test('findFile returns null when no extension matches', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final found = await YoutubeCache.instance.findFile('ghost');
      expect(found, isNull);
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  Max limits (static)
  // ═════════════════════════════════════════════════════════════════

  group('max limits', () {
    test('default maxAudioCacheMB is 5120', () {
      expect(YoutubeCache.maxAudioCacheMB, 5120);
    });

    test('default maxArtworkCacheMB is 500', () {
      expect(YoutubeCache.maxArtworkCacheMB, 500);
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  Protected / eviction
  // ═════════════════════════════════════════════════════════════════

  group('protected id', () {
    test('setProtectedId sets and can be cleared', () {
      // ignore: invalid_use_of_visible_for_testing_member
      YoutubeCache.instance.setProtectedId('playing_now');
      // Косвенно проверяем через clearAudioCache:
      // файл с protected id не должен удаляться.
      // Прямой геттер отсутствует — проверяем поведение.
      // ignore: invalid_use_of_visible_for_testing_member
      expect(() => YoutubeCache.instance.setProtectedId(null), returnsNormally);
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  Eviction (runEvictionForTesting)
  // ═════════════════════════════════════════════════════════════════

  group('eviction', () {
    test('eviction does not crash on empty dir', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      await YoutubeCache.instance.runEvictionForTesting();
      // Не должно быть исключений
    });

    test('evict removes single file', () async {
      final id = 'to_delete';
      final f = File(p.join(audioDir.path, '$id.mp3'));
      await f.writeAsString('x' * 100); // 100 байт
      expect(await f.exists(), true);

      await YoutubeCache.instance.evict(id);
      expect(await f.exists(), false);
    });

    test('evict removes file with any extension', () async {
      final f1 = File(p.join(audioDir.path, 'multi.mp3'));
      final f2 = File(p.join(audioDir.path, 'multi.m4a'));
      await f1.writeAsString('a');
      await f2.writeAsString('b');
      expect(await f1.exists(), true);
      expect(await f2.exists(), true);

      await YoutubeCache.instance.evict('multi');
      expect(await f1.exists(), false);
      expect(await f2.exists(), false);
    });

    test('evict non-existent file does not throw', () async {
      await YoutubeCache.instance.evict('no_such_file');
      // Не падает
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  Audio extensions
  // ═════════════════════════════════════════════════════════════════

  group('audioExtensions', () {
    test('contains mp3, m4a, webm', () {
      expect(YoutubeCache.audioExtensions, contains('mp3'));
      expect(YoutubeCache.audioExtensions, contains('m4a'));
      expect(YoutubeCache.audioExtensions, contains('webm'));
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  clearAllCache
  // ═════════════════════════════════════════════════════════════════
  //  Полная очистка: аудио + обложки CachedNetworkImage на диске +
  //  SQLite-кэш обложек + кастомные обложки (файлы custom_artworks/
  //  с подкаталогом playlists/) + RAM-кэш ArtworkHelper.
  //
  //  Использует: setAudioDirForTesting / setArtworkDirForTesting (YoutubeCache),
  //  setDocsDirForTesting (ArtworkHelper) и TestHarness для БД.

  group('clearAllCache', () {
    late Directory docsDir;

    setUp(() async {
      await TestHarness.setUpDb();
      // Сбрасываем статическое состояние ArtworkHelper между тестами.
      ArtworkHelper.resetInit();
      docsDir = Directory(p.join(tempDir.path, 'docs'));
      docsDir.createSync(recursive: true);
      // Подменяем каталог документов для ArtworkHelper, минуя path_provider
      // ignore: invalid_use_of_visible_for_testing_member
      ArtworkHelper.setDocsDirForTesting(docsDir);
    });

    tearDown(() async {
      await TestHarness.tearDownDb();
    });

    /// Заполняет «кэш» как в реальном приложении:
    /// аудио, обложки CachedNetworkImage, кастомные обложки на диске
    /// (включая playlists/) и RAM-кэш ArtworkHelper.
    Future<({File trackFile, File artFile, File customFile})> seedCache(
        {String protectedId = ''}) async {
      // Аудио-кэш: трек-файл (и защищённый, если задан).
      final trackId = 'some_id';
      final trackFile = File(p.join(audioDir.path, '$trackId.mp3'));
      await trackFile.writeAsString('audio');
      if (protectedId.isNotEmpty) {
        await File(
          p.join(audioDir.path, '$protectedId.mp3'),
        ).writeAsString('audio-playing');
      }

      // Обложки CachedNetworkImage на диске.
      final artFile = File(p.join(artworkDir.path, 'artwork_cache_file.img'));
      await artFile.writeAsString('art');

      // Кастомные обложки на диске: треки + playlists/.
      // Каталоги строим конкатенацией через '/', ровно как production-код
      // (init() → '${appDir.path}/custom_artworks'). На Windows это даёт те же
      // строки путей в Directory.listSync(), что и внутри init(), поэтому
      // loadCustomArtworks() по точному строковому сравнению их находит.
      final customArtRoot = Directory('${docsDir.path}/custom_artworks');
      final playlistsDir = Directory('${customArtRoot.path}/playlists');
      playlistsDir.createSync(recursive: true);
      final customFile = File('${customArtRoot.path}/$trackId.jpg');
      await customFile.writeAsString('custom-track');
      await File(
        '${playlistsDir.path}/cover_123.jpg',
      ).writeAsString('custom-cover');

      // Путь «как его видит init()»: Directory.listSync() возвращает путь,
      // который init() кладёт в existingFiles, и с ним loadCustomArtworks()
      // сравнивает строки из БД. Берём путь прямо из listSync (на Windows он
      // содержит нативный разделитель, которого нет в customFile.path).
      final customArtPath = customArtRoot
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('$trackId.jpg'))
          .path;

      // RAM-кэш ArtworkHelper через реальный путь init() → БД.
      await AppDatabase.instance.setCustomArtworkPath(trackId, customArtPath);
      ArtworkHelper.resetInit();
      await ArtworkHelper.init();
      expect(ArtworkHelper.getCustomArtworkSync(trackId), customArtPath);

      return (trackFile: trackFile, artFile: artFile, customFile: customFile);
    }

    test('удаляет аудио, обложки и кастомные обои (файлы + RAM-кэш)',
        () async {
      final files = await seedCache();

      await YoutubeCache.instance.clearAllCache();

      // Аудио удалено.
      expect(await files.trackFile.exists(), false);
      // Обложки CachedNetworkManager удалены.
      expect(await files.artFile.exists(), false);
      // Кастомные обои на диске удалены (включая вложенный playlists/).
      expect(await files.customFile.exists(), false);
      final playlistsDir =
          Directory(p.join(docsDir.path, 'custom_artworks', 'playlists'));
      expect(await playlistsDir.exists(), false);
      // RAM-кэш ArtworkHelper сброшен.
      expect(ArtworkHelper.getCustomArtworkSync('some_id'), isNull);
      // SQLite-записи кастомных обоев тоже удалены clearCacheData.
      expect(
        await AppDatabase.instance.getCustomArtworkPath('some_id'),
        isNull,
      );
    });

    test('protected id: файл играющего трека не удаляется', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      YoutubeCache.instance.setProtectedId('playing');
      final files = await seedCache(protectedId: 'playing');

      await YoutubeCache.instance.clearAllCache();

      // Аудио-файл играющего трека выживает.
      expect(await File(p.join(audioDir.path, 'playing.mp3')).exists(), true);
      // Остальное удаляется.
      expect(await files.trackFile.exists(), false);
      expect(await files.artFile.exists(), false);
      expect(await files.customFile.exists(), false);
      expect(ArtworkHelper.getCustomArtworkSync('some_id'), isNull);
    });
  });
}
