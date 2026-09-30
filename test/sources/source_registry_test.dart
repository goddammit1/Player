import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/soulseek_settings_repository.dart';
import 'package:player/sources/source_registry.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  group('SourceRegistry', () {
    setUp(() async {
      await TestHarness.setUpDb();
      // Сбрасываем Soulseek feature flag в false (значение по умолчанию).
      await AppDatabase.instance.removeSetting(
        SoulseekSettingsRepository.keyEnabled,
      );
      await SourceRegistry.loadSoulseekEnabled();
    });

    tearDown(() async {
      await SourceRegistry.instance.disposeAll();
      await TestHarness.tearDownDb();
    });

    test('registerDefaults registers muzmo, soundcloud, youtube, soulseek',
        () {
      SourceRegistry.instance.registerDefaults();

      final all = SourceRegistry.instance.all;
      final ids = all.map((s) => s.id).toSet();

      expect(ids.contains('muzmo'), isTrue);
      expect(ids.contains('soundcloud'), isTrue);
      expect(ids.contains('youtube'), isTrue);
      expect(ids.contains('soulseek'), isTrue);
      expect(all.length, 4);
    });

    test('require returns source for registered id', () {
      SourceRegistry.instance.registerDefaults();
      final s = SourceRegistry.instance.require('muzmo');
      expect(s.id, 'muzmo');
      expect(s.displayName, 'Muzmo');
    });

    test('require returns soulseek source', () {
      SourceRegistry.instance.registerDefaults();
      final s = SourceRegistry.instance.require('soulseek');
      expect(s.id, 'soulseek');
      expect(s.displayName, 'Soulseek');
    });

    test('require throws StateError for unregistered id', () {
      expect(
        () => SourceRegistry.instance.require('unknown_source'),
        throwsStateError,
      );
    });

    test('all returns all registered sources', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.all.length, 4);
    });

    test('searchable excludes youtube and soulseek (disabled by default)', () {
      SourceRegistry.instance.registerDefaults();
      final searchable = SourceRegistry.instance.searchable;
      final ids = searchable.map((s) => s.id).toSet();

      expect(ids.contains('youtube'), isFalse,
          reason: 'YouTube должен быть исключён из searchable');
      expect(ids.contains('soulseek'), isFalse,
          reason: 'Soulseek должен быть исключён, если feature flag выключен');
      expect(ids.contains('muzmo'), isTrue);
      expect(ids.contains('soundcloud'), isTrue);
      expect(searchable.length, 2);
    });

    test('searchable includes soulseek when feature flag is enabled', () async {
      await SourceRegistry.setSoulseekEnabled(true);
      SourceRegistry.instance.registerDefaults();
      final searchable = SourceRegistry.instance.searchable;
      final ids = searchable.map((s) => s.id).toSet();

      expect(ids.contains('soulseek'), isTrue,
          reason: 'Soulseek должен быть в searchable, если feature flag включён');
      expect(searchable.length, 3);
    });

    test('isDisabled returns true for youtube and soulseek, false for others',
        () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('youtube'), isTrue);
      expect(SourceRegistry.instance.isDisabled('soulseek'), isTrue);
      expect(SourceRegistry.instance.isDisabled('muzmo'), isFalse);
      expect(SourceRegistry.instance.isDisabled('soundcloud'), isFalse);
      expect(SourceRegistry.instance.isDisabled('nonexistent'), isFalse);
    });

    test('isDisabled returns false for soulseek when enabled', () async {
      await SourceRegistry.setSoulseekEnabled(true);
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('soulseek'), isFalse);
    });

    test('setSoulseekEnabled(false) re-disables soulseek in searchable',
        () async {
      // Включаем, регистрируем, выключаем.
      await SourceRegistry.setSoulseekEnabled(true);
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('soulseek'), isFalse);

      await SourceRegistry.setSoulseekEnabled(false);
      expect(SourceRegistry.instance.isDisabled('soulseek'), isTrue);
      expect(
        SourceRegistry.instance.searchable
            .map((s) => s.id)
            .contains('soulseek'),
        isFalse,
      );
    });

    test('loadSoulseekEnabled reads value from DB', () async {
      await SoulseekSettingsRepository.instance.setEnabled(true);
      await SourceRegistry.loadSoulseekEnabled();
      expect(SourceRegistry.isSoulseekEnabled, isTrue);
    });

    test('loadSoulseekEnabled defaults to false when key is missing', () async {
      await SourceRegistry.loadSoulseekEnabled();
      expect(SourceRegistry.isSoulseekEnabled, isFalse);
    });

    test('get returns null for unregistered id', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.get('unknown'), isNull);
    });

    test('get returns soulseek source after registerDefaults', () {
      SourceRegistry.instance.registerDefaults();
      final s = SourceRegistry.instance.get('soulseek');
      expect(s, isNotNull);
      expect(s!.id, 'soulseek');
    });
  });
}
