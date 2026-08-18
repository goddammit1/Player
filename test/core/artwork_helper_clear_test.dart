import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player/core/app_database.dart';
import 'package:player/core/artwork_helper.dart';

import '../setup/test_harness.dart';

/// Тесты для [ArtworkHelper.clearAllCustomArtwork] — полной очистки кастомных
/// обложек при «Clear all cache» (коммит fix(cache)).
///
/// path_provider подменяется тестовым хуком [ArtworkHelper.setDocsDirForTesting]
/// (канонический для этого проекта способ — как setAudioDirForTesting),
/// БД — через [TestHarness] (sqflite_common_ffi, файл в temp-каталоге).
void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  late Directory docsDir;

  setUp(() async {
    await TestHarness.setUpDb();
    // Сбрасываем статическое состояние ArtworkHelper между тестами.
    ArtworkHelper.resetInit();
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(null);

    tempDir = Directory.systemTemp.createTempSync('artwork_helper_clear_');
    docsDir = Directory(p.join(tempDir.path, 'docs'));
    docsDir.createSync(recursive: true);
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(docsDir);
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    ArtworkHelper.setDocsDirForTesting(null);
    await TestHarness.tearDownDb();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ArtworkHelper.clearAllCustomArtwork', () {
    test('удаляет все файлы, подкаталог playlists и сбрасывает RAM-кэш',
        () async {
      // Каталоги и файлы создаём, как это делает production-код
      // (pickAndSaveArtwork → '${artDir.path}/$trackId.jpg').
      final artDir = Directory('${docsDir.path}/custom_artworks');
      final playlistsDir = Directory('${artDir.path}/playlists');
      playlistsDir.createSync(recursive: true);

      final file1 = File('${artDir.path}/track1.jpg');
      final file2 = File('${artDir.path}/track2.jpg');
      final cover = File('${playlistsDir.path}/cover_123.jpg');
      await file1.writeAsString('img1');
      await file2.writeAsString('img2');
      await cover.writeAsString('img3');

      // Пути «как их видит init()»: Directory.listSync() возвращает пути,
      // которые init() кладёт в existingFiles, и с ними loadCustomArtworks()
      // сравнивает строки из БД. Пишем в БД ровно эти пути — на Windows
      // listSync добавляет нативный разделитель, и путь из p.join/File.path
      // с ним не совпадёт (а на Android production-код пишет пути с '/',
      // которые listSync и возвращает).
      String pathOnDisk(String fileName) => artDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith(fileName))
          .path;

      // Наполняем RAM-кэш ArtworkHelper: запись в БД + init() читает её
      // (файлы на диске существуют — loadCustomArtworks их пропустит в кэш).
      await AppDatabase.instance.setCustomArtworkPath('t1', pathOnDisk('track1.jpg'));
      await AppDatabase.instance.setCustomArtworkPath('t2', pathOnDisk('track2.jpg'));
      await ArtworkHelper.init();

      // Кэш реально наполнен — getCustomArtworkSync отдаёт пути.
      expect(ArtworkHelper.getCustomArtworkSync('t1'), pathOnDisk('track1.jpg'));
      expect(ArtworkHelper.getCustomArtworkSync('t2'), pathOnDisk('track2.jpg'));

      await ArtworkHelper.clearAllCustomArtwork();

      // Все файлы удалены, включая вложенный playlists/.
      expect(await file1.exists(), false);
      expect(await file2.exists(), false);
      expect(await cover.exists(), false);
      expect(await playlistsDir.exists(), false);
      // Корневой каталог остался, но пуст.
      expect(artDir.listSync(), isEmpty);

      // RAM-кэш сброшен: для ранее известных trackId — null.
      expect(ArtworkHelper.getCustomArtworkSync('t1'), isNull);
      expect(ArtworkHelper.getCustomArtworkSync('t2'), isNull);

      // Ключевая проверка сброса флага инициализации (resetInit):
      // следующий init() обязан перечитать БД заново. Если resetInit()
      // не был вызван — _initialized останется true, init() вернётся сразу
      // и новая запись в кэш не попадёт.
      final file3 = File('${artDir.path}/track3.jpg');
      await file3.writeAsString('img4');
      await AppDatabase.instance.setCustomArtworkPath(
          't3', pathOnDisk('track3.jpg'));
      await ArtworkHelper.init();
      expect(ArtworkHelper.getCustomArtworkSync('t3'), pathOnDisk('track3.jpg'));
    });

    test('повторный вызов не кидает исключение', () async {
      final artDir = Directory('${docsDir.path}/custom_artworks');
      final playlistsDir = Directory('${artDir.path}/playlists');
      playlistsDir.createSync(recursive: true);
      await File('${artDir.path}/track1.jpg').writeAsString('x');
      await File('${playlistsDir.path}/cover.jpg').writeAsString('y');

      await ArtworkHelper.clearAllCustomArtwork();
      // Повторный вызов после полной очистки — тоже без исключений.
      await ArtworkHelper.clearAllCustomArtwork();
    });

    test('не кидает исключение при несуществующем каталоге', () async {
      // В docsDir каталога custom_artworks нет вообще.
      await ArtworkHelper.clearAllCustomArtwork();
    });
  });
}