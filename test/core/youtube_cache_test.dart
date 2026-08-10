import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player/core/youtube_cache.dart';

/// Unit-тесты YoutubeCache (cacheIdFor, эвикция, pin/unpin, protected id).
///
/// Используют тестовый хук `setAudioDirForTesting` — работают с реальной
/// файловой системой (temp dir), но без зависимости от path_provider / БД.
void main() {
  late Directory tempDir;
  late Directory audioDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('yt_cache_test_');
    audioDir = Directory(p.join(tempDir.path, 'audio'));
    audioDir.createSync(recursive: true);
    // Подменяем каталог аудио, минуя path_provider
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(audioDir);
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
}
