// test/database/soulseek_migration_v3_test.dart
//
// Фаза A — тест миграции v3 (настройки Soulseek SP → SQLite).
//
// Покрывает:
// - SP содержит soulseek_* значения → migrateFromSharedPreferences →
//   значения в таблице settings, флаг migration_v3_soulseek выставлен
// - Отсутствующие в SP ключи материализуются дефолтами
// - purgeLegacySoulseekPrefs удаляет legacy soulseek_* ключи из SP
//   (кроме soulseek_cache_index) после установки флага миграции
// - Повторный вызов миграции идемпотентен (значения в БД не затираются
//   значениями из SP)

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/soulseek_settings_repository.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  setUp(() async {
    await TestHarness.setUpDb();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async => await TestHarness.tearDownDb());

  Future<void> migrate() async {
    final sp = await SharedPreferences.getInstance();
    final allSettings = <String, String>{};
    for (final key in sp.getKeys()) {
      if (key.startsWith('flutter.')) continue;
      final value = sp.get(key);
      if (value != null) allSettings[key] = value.toString();
    }
    await AppDatabase.instance.migrateFromSharedPreferences(
      playlistsJson: '',
      listenHistoryJson: '',
      historyLimit: 100,
      searchHistory: const [],
      allSettings: allSettings,
    );
  }

  group('Migration v3 (soulseek SP → SQLite)', () {
    test('soulseek_* values from SP land in settings table', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('soulseek_enabled', true);
      await sp.setInt('soulseek_listen_port', 12345);
      await sp.setInt('soulseek_cache_limit_mb', 2048);
      await sp.setInt('soulseek_max_parallel_downloads', 5);
      await sp.setBool('soulseek_prefer_lossless', true);
      await sp.setString('soulseek_allowed_formats', 'flac,wav');
      await sp.setInt('soulseek_max_file_size_mb', 300);
      await sp.setInt('soulseek_search_timeout_sec', 42);
      await sp.setString('soulseek_sharing_directory', '/music');
      await sp.setString('soulseek_username_display', 'alice');

      await migrate();

      final db = await AppDatabase.instance.database;
      final rows = await db.query('settings');
      final map = {for (final r in rows) r['key'] as String: r['value'] as String};

      expect(map['soulseek_enabled'], 'true');
      expect(map['soulseek_listen_port'], '12345');
      expect(map['soulseek_cache_limit_mb'], '2048');
      expect(map['soulseek_max_parallel_downloads'], '5');
      expect(map['soulseek_prefer_lossless'], 'true');
      expect(map['soulseek_allowed_formats'], 'flac,wav');
      expect(map['soulseek_max_file_size_mb'], '300');
      expect(map['soulseek_search_timeout_sec'], '42');
      expect(map['soulseek_sharing_directory'], '/music');
      expect(map['soulseek_username_display'], 'alice');
      expect(map[AppDatabase.migrationV3SoulseekFlag], '1');
    });

    test('missing SP values are materialized with defaults', () async {
      await migrate();

      final db = await AppDatabase.instance.database;
      final rows = await db.query('settings');
      final map = {for (final r in rows) r['key'] as String: r['value'] as String};

      expect(map['soulseek_enabled'], 'false');
      expect(map['soulseek_listen_port'], '24150');
      expect(map['soulseek_cache_limit_mb'], '1024');
      expect(map['soulseek_max_parallel_downloads'], '3');
      expect(map['soulseek_prefer_lossless'], 'false');
      expect(map['soulseek_allowed_formats'], 'flac,wav,alac,mp3,aac,ogg');
      expect(map['soulseek_max_file_size_mb'], '0');
      expect(map['soulseek_search_timeout_sec'], '10');
      expect(map['soulseek_sharing_directory'], '');
    });

    test('loadAll reads migrated values', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('soulseek_search_timeout_sec', 30);
      await sp.setBool('soulseek_enabled', true);

      await migrate();

      final s = await SoulseekSettingsRepository.instance.loadAll();
      expect(s.enabled, isTrue);
      expect(s.searchTimeoutSec, 30);
    });

    test('migration is idempotent: rerun does not overwrite DB values',
        () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('soulseek_search_timeout_sec', 30);
      await migrate();

      // Пользователь изменил значение в БД уже после миграции.
      await SoulseekSettingsRepository.instance.setSearchTimeoutSec(60);

      await migrate(); // повторный запуск (флаг уже стоит — фаза пропущена)

      expect(
        (await SoulseekSettingsRepository.instance.loadAll()).searchTimeoutSec,
        60,
      );
    });
  });

  group('purgeLegacySoulseekPrefs', () {
    test('removes legacy soulseek_* keys from SP after migration', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('soulseek_search_timeout_sec', 42);
      await sp.setBool('soulseek_enabled', true);
      // Индекс кэша — НЕ настройка, purge его не трогает.
      await sp.setStringList('soulseek_cache_index', ['ck1', 'ck2']);
      await sp.setString('unrelated_key', 'keep-me');

      await migrate();
      await SoulseekSettingsRepository.purgeLegacySoulseekPrefs();

      expect(sp.containsKey('soulseek_enabled'), isFalse);
      expect(sp.containsKey('soulseek_search_timeout_sec'), isFalse);
      expect(sp.containsKey('soulseek_username_display'), isFalse);
      expect(sp.containsKey('soulseek_cache_index'), isTrue,
          reason: 'soulseek_cache_index — индекс кэша, не настройка');
      expect(sp.getString('unrelated_key'), 'keep-me');
    });

    test('no-op when migration flag is absent', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('soulseek_search_timeout_sec', 42);

      // Миграцию не выполняли — флага нет, purge не должен удалять.
      await SoulseekSettingsRepository.purgeLegacySoulseekPrefs();

      expect(sp.containsKey('soulseek_search_timeout_sec'), isTrue);
    });
  });
}
