import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/sources/source_registry.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  group('SourceRegistry', () {
    setUp(() async {
      await TestHarness.setUpDb();
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

    // Переключателя «Show in search» больше нет: Soulseek в поиске везде,
    // где есть нативная часть (тесты по умолчанию идут как Android).
    test('searchable excludes youtube, includes soulseek on Android', () {
      SourceRegistry.instance.registerDefaults();
      final searchable = SourceRegistry.instance.searchable;
      final ids = searchable.map((s) => s.id).toSet();

      expect(ids.contains('youtube'), isFalse,
          reason: 'YouTube должен быть исключён из searchable');
      expect(ids.contains('soulseek'), isTrue);
      expect(ids.contains('muzmo'), isTrue);
      expect(ids.contains('soundcloud'), isTrue);
      expect(searchable.length, 3);
    });

    test('soulseek is disabled for search where it is unavailable', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('soulseek'), isTrue);
      expect(
        SourceRegistry.instance.searchable
            .map((s) => s.id)
            .contains('soulseek'),
        isFalse,
      );
    });

    test('isDisabled returns true for youtube only', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('youtube'), isTrue);
      expect(SourceRegistry.instance.isDisabled('soulseek'), isFalse);
      expect(SourceRegistry.instance.isDisabled('muzmo'), isFalse);
      expect(SourceRegistry.instance.isDisabled('soundcloud'), isFalse);
      expect(SourceRegistry.instance.isDisabled('nonexistent'), isFalse);
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
