import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/youtube_source.dart';
import 'package:player/sources/source_registry.dart';

/// Unit-тесты YoutubeSource (без сети).
/// Вынесены из youtube_source_test.dart, чтобы выполняться в обычном прогоне
/// (без тега live) вместе с остальными unit-тестами.
void main() {
  group('YoutubeSource (unit)', () {
    late YoutubeSource source;

    setUp(() {
      source = YoutubeSource();
    });

    tearDown(() {
      source.dispose();
    });

    test('has correct id and displayName', () {
      expect(source.id, 'youtube');
      expect(source.displayName, 'YouTube');
    });

    test('dispose cleans up without error', () async {
      await source.dispose();
      // Не должен падать при повторном dispose
      await source.dispose();
    });
  });

  group('SourceRegistry youtube', () {
    test('is registered but disabled for search', () {
      SourceRegistry.instance.registerDefaults();

      // Зарегистрирован
      expect(SourceRegistry.instance.require('youtube').id, 'youtube');

      // Но отключён для поиска
      expect(SourceRegistry.instance.isDisabled('youtube'), isTrue);

      SourceRegistry.instance.disposeAll();
    });
  });
}
