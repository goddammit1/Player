import 'package:flutter_test/flutter_test.dart';

import 'package:player/sources/source_registry.dart';

void main() {
  group('SourceRegistry', () {
    setUp(() {
      // Не вызываем registerDefaults — тестируем чистый реестр.
    });

    tearDown(() async {
      await SourceRegistry.instance.disposeAll();
    });

    test('registerDefaults registers muzmo, soundcloud, youtube', () {
      SourceRegistry.instance.registerDefaults();

      final all = SourceRegistry.instance.all;
      final ids = all.map((s) => s.id).toSet();

      expect(ids.contains('muzmo'), isTrue);
      expect(ids.contains('soundcloud'), isTrue);
      expect(ids.contains('youtube'), isTrue);
      expect(all.length, 3);
    });

    test('require returns source for registered id', () {
      SourceRegistry.instance.registerDefaults();
      final s = SourceRegistry.instance.require('muzmo');
      expect(s.id, 'muzmo');
      expect(s.displayName, 'Muzmo');
    });

    test('require throws StateError for unregistered id', () {
      expect(
        () => SourceRegistry.instance.require('unknown_source'),
        throwsStateError,
      );
    });

    test('all returns all registered sources', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.all.length, 3);
    });

    test('searchable excludes youtube', () {
      SourceRegistry.instance.registerDefaults();
      final searchable = SourceRegistry.instance.searchable;
      final ids = searchable.map((s) => s.id).toSet();

      expect(ids.contains('youtube'), isFalse,
          reason: 'YouTube должен быть исключён из searchable');
      expect(ids.contains('muzmo'), isTrue);
      expect(ids.contains('soundcloud'), isTrue);
      expect(searchable.length, 2);
    });

    test('isDisabled returns true for youtube, false for others', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.isDisabled('youtube'), isTrue);
      expect(SourceRegistry.instance.isDisabled('muzmo'), isFalse);
      expect(SourceRegistry.instance.isDisabled('soundcloud'), isFalse);
      expect(SourceRegistry.instance.isDisabled('nonexistent'), isFalse);
    });

    test('get returns null for unregistered id', () {
      SourceRegistry.instance.registerDefaults();
      expect(SourceRegistry.instance.get('unknown'), isNull);
    });
  });
}
