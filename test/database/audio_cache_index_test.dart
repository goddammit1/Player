// Индекс метаданных аудио-кэша (таблица audio_cache_index, БД v6):
// миграция v5 → v6 и операции DAO через фасад AppDatabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/models/track.dart';

import '../setup/test_harness.dart';

Track _track(String id, {String title = 'Song', String? artworkUrl}) => Track(
      id: id,
      sourceId: 'muzmo',
      title: title,
      artist: 'Artist',
      duration: const Duration(seconds: 200),
      artworkUrl: artworkUrl,
      qualityLabel: 'HD',
      extra: const {'bitrate': 320},
    );

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('Migration v5→v6', () {
    test('создаёт audio_cache_index, данные v5 сохраняются', () async {
      await AppDatabase.instance.close();
      final dbPath = AppDatabase.testDbPath!;
      final v5db = await openDatabase(
        dbPath,
        version: 5,
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
          await db.execute('''CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY, name TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            manual_order_json TEXT)''');
        },
      );
      await v5db.insert('settings', {'key': 'theme', 'value': 'dark'});
      await v5db.close();

      final db = await AppDatabase.instance.database;

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='audio_cache_index'",
      );
      expect(tables, hasLength(1));
      expect(await AppDatabase.instance.getSetting('theme'), 'dark');

      // Таблица рабочая после апгрейда.
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _track('1'));
      expect(await AppDatabase.instance.getAudioCacheIndex(), contains('muzmo_1'));
    });
  });

  group('audio_cache_index DAO', () {
    test('upsert → getAll возвращает трек целиком', () async {
      final at = DateTime(2026, 10, 5, 12);
      await AppDatabase.instance
          .upsertAudioCacheEntry('muzmo_1', _track('1'), cachedAt: at);

      final entry = (await AppDatabase.instance.getAudioCacheIndex())['muzmo_1']!;
      expect(entry.track.globalId, 'muzmo:1');
      expect(entry.track.title, 'Song');
      expect(entry.track.duration, const Duration(seconds: 200));
      expect(entry.track.qualityLabel, 'HD');
      expect(entry.track.extra['bitrate'], 320);
      expect(entry.cachedAt, at);
    });

    test('повторный upsert обновляет метаданные, но не дату кэширования',
        () async {
      final first = DateTime(2026, 10, 1);
      await AppDatabase.instance
          .upsertAudioCacheEntry('muzmo_1', _track('1'), cachedAt: first);
      await AppDatabase.instance.upsertAudioCacheEntry(
        'muzmo_1',
        _track('1', title: 'Renamed', artworkUrl: 'https://img/1.jpg'),
        cachedAt: DateTime(2026, 10, 7),
      );

      final entry = (await AppDatabase.instance.getAudioCacheIndex())['muzmo_1']!;
      expect(entry.track.title, 'Renamed');
      expect(entry.track.artworkUrl, 'https://img/1.jpg');
      expect(entry.cachedAt, first);
    });

    test('resetCachedAt: новая загрузка сбрасывает дату кэширования',
        () async {
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _track('1'),
          cachedAt: DateTime(2026, 9, 1));
      final now = DateTime(2026, 10, 7, 9);
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _track('1'),
          cachedAt: now, resetCachedAt: true);

      final entry = (await AppDatabase.instance.getAudioCacheIndex())['muzmo_1']!;
      expect(entry.cachedAt, now);
    });

    test('removeAudioCacheEntries и clearAudioCacheIndex(keep:)', () async {
      for (final id in ['1', '2', '3']) {
        await AppDatabase.instance.upsertAudioCacheEntry('muzmo_$id', _track(id));
      }

      await AppDatabase.instance.removeAudioCacheEntries(['muzmo_1']);
      expect(
        (await AppDatabase.instance.getAudioCacheIndex()).keys,
        unorderedEquals(['muzmo_2', 'muzmo_3']),
      );

      await AppDatabase.instance.clearAudioCacheIndex(keep: 'muzmo_3');
      expect(
        (await AppDatabase.instance.getAudioCacheIndex()).keys,
        ['muzmo_3'],
      );
    });

    test('индекс аудио-кэша не попадает в полный бэкап', () async {
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _track('1'));
      final backup = await AppDatabase.instance.exportFullBackup();
      expect(backup.contains('muzmo_1'), isFalse);
    });
  });
}
