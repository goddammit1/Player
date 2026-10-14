// Юнит-тесты WindowsDataMigration (этап 4.1): перенос БД, кастомных
// обложек и аудиокэша со старых путей Windows и переписывание абсолютных
// путей в БД. Каталоги — временные, path_provider не используется.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:player/core/database/app_database.dart';
import 'package:player/core/platform/windows_data_migration.dart';

import '../setup/test_harness.dart';

void main() {
  late Directory root;
  late WindowsDataMigration migration;

  Directory dir(String name) => Directory(p.join(root.path, name));

  File write(Directory base, String relative, [String content = 'x']) {
    final file = File(p.join(base.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('player_migration_');
    migration = WindowsDataMigration(
      legacyDataDir: dir('Documents')..createSync(),
      dataDir: dir('Roaming'),
      legacyCacheDir: dir('Temp')..createSync(),
      cacheDir: dir('Local'),
    );
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('moveDatabase', () {
    test('переносит БД вместе с -wal/-shm', () async {
      write(dir('Documents'), 'player_data.db', 'db');
      write(dir('Documents'), 'player_data.db-wal', 'wal');
      write(dir('Documents'), 'player_data.db-shm', 'shm');

      expect(await migration.moveDatabase(), isTrue);

      for (final name in ['player_data.db', 'player_data.db-wal', 'player_data.db-shm']) {
        expect(File(p.join(dir('Roaming').path, name)).existsSync(), isTrue,
            reason: name);
        expect(File(p.join(dir('Documents').path, name)).existsSync(), isFalse,
            reason: name);
      }
      expect(
        File(p.join(dir('Roaming').path, 'player_data.db')).readAsStringSync(),
        'db',
      );
    });

    test('без старой БД — ничего не делает', () async {
      expect(await migration.moveDatabase(), isTrue);
      expect(dir('Roaming').existsSync(), isFalse);
    });

    test('новая БД уже есть — старая не трогается', () async {
      write(dir('Documents'), 'player_data.db', 'old');
      write(dir('Roaming'), 'player_data.db', 'new');

      expect(await migration.moveDatabase(), isTrue);
      expect(
        File(p.join(dir('Roaming').path, 'player_data.db')).readAsStringSync(),
        'new',
      );
      expect(
        File(p.join(dir('Documents').path, 'player_data.db')).existsSync(),
        isTrue,
      );
    });

    test('занятая БД остаётся на месте, перенесённое откатывается', () async {
      write(dir('Documents'), 'player_data.db', 'db');
      final wal = write(dir('Documents'), 'player_data.db-wal', 'wal');
      // Открытый дескриптор — как у другого экземпляра приложения: на
      // Windows такой файл нельзя ни переименовать, ни удалить.
      final handle = wal.openSync(mode: FileMode.append);
      try {
        expect(await migration.moveDatabase(), isFalse);
      } finally {
        handle.closeSync();
      }
      expect(
        File(p.join(dir('Documents').path, 'player_data.db')).readAsStringSync(),
        'db',
      );
      expect(wal.existsSync(), isTrue);
      expect(
        File(p.join(dir('Roaming').path, 'player_data.db')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(dir('Roaming').path, 'player_data.db-wal')).existsSync(),
        isFalse,
      );
    }, skip: !Platform.isWindows ? 'блокировка файлов — только Windows' : null);
  });

  test('moveCustomArtwork переносит вложенные файлы и чистит старый каталог',
      () async {
    write(dir('Documents'), p.join('custom_artworks', 'a.jpg'), 'a');
    write(dir('Documents'), p.join('custom_artworks', 'playlists', 'c.jpg'), 'c');
    // Уже есть в новом месте — главнее, дубль удаляется.
    write(dir('Roaming'), p.join('custom_artworks', 'b.jpg'), 'new');
    write(dir('Documents'), p.join('custom_artworks', 'b.jpg'), 'old');

    await migration.moveCustomArtwork();

    final art = Directory(p.join(dir('Roaming').path, 'custom_artworks'));
    expect(File(p.join(art.path, 'a.jpg')).readAsStringSync(), 'a');
    expect(File(p.join(art.path, 'playlists', 'c.jpg')).readAsStringSync(), 'c');
    expect(File(p.join(art.path, 'b.jpg')).readAsStringSync(), 'new');
    expect(
      Directory(p.join(dir('Documents').path, 'custom_artworks')).existsSync(),
      isFalse,
    );
  });

  test('moveAudioCache переносит кэш, недокачанные .part удаляет', () async {
    write(dir('Temp'), p.join('yt_audio_cache', 'muzmo_1.mp3'));
    write(dir('Temp'), p.join('yt_audio_cache', 'muzmo_1.mime'));
    write(dir('Temp'), p.join('yt_audio_cache', 'muzmo_2.mp3.part'));

    await migration.moveAudioCache();

    final audio = p.join(dir('Local').path, 'yt_audio_cache');
    expect(File(p.join(audio, 'muzmo_1.mp3')).existsSync(), isTrue);
    expect(File(p.join(audio, 'muzmo_1.mime')).existsSync(), isTrue);
    expect(File(p.join(audio, 'muzmo_2.mp3.part')).existsSync(), isFalse);
    expect(Directory(p.join(dir('Temp').path, 'yt_audio_cache')).existsSync(),
        isFalse);
  });

  group('rewriteStoredPaths', () {
    setUpAll(TestHarness.ensureInitialized);
    setUp(TestHarness.setUpDb);
    tearDown(TestHarness.tearDownDb);

    test('переписывает пути custom_artworks (обычные и в JSON), ставит отметку',
        () async {
      final m = WindowsDataMigration(
        legacyDataDir: Directory(r'C:\Users\u\Documents'),
        dataDir: Directory(r'C:\Users\u\AppData\Roaming\com.player\player'),
        legacyCacheDir: Directory(r'C:\Temp'),
        cacheDir: Directory(r'C:\Local'),
      );
      final db = AppDatabase.instance;
      await db.setSetting(
          'custom_art_v1_t1', r'C:\Users\u\Documents/custom_artworks/t1.jpg');
      await db.setSetting(
          'raw_backslash', r'C:\Users\u\Documents\custom_artworks\t2.jpg');
      await db.setSetting('json',
          r'{"artworkUrl":"C:\\Users\\u\\Documents/custom_artworks/t3.jpg"}');
      await db.setSetting('other', r'C:\Users\u\Documents\backup.json');

      await m.rewriteStoredPaths(db);

      expect(await db.getSetting('custom_art_v1_t1'),
          r'C:\Users\u\AppData\Roaming\com.player\player/custom_artworks/t1.jpg');
      expect(await db.getSetting('raw_backslash'),
          r'C:\Users\u\AppData\Roaming\com.player\player\custom_artworks\t2.jpg');
      expect(
        await db.getSetting('json'),
        r'{"artworkUrl":"C:\\Users\\u\\AppData\\Roaming\\com.player\\player/custom_artworks/t3.jpg"}',
      );
      // Пути вне custom_artworks не трогаются.
      expect(await db.getSetting('other'), r'C:\Users\u\Documents\backup.json');
      expect(await db.getSetting(WindowsDataMigration.markerKey), '1');

      // Повторный запуск — no-op (отметка уже стоит).
      await db.setSetting(
          'late', r'C:\Users\u\Documents\custom_artworks\t4.jpg');
      await m.rewriteStoredPaths(db);
      expect(await db.getSetting('late'),
          r'C:\Users\u\Documents\custom_artworks\t4.jpg');
    });
  });
}
