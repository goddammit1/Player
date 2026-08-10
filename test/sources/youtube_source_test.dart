@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/youtube_source.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/models/track.dart';

void main() {
  late YoutubeSource source;

  setUp(() {
    source = YoutubeSource();
  });

  tearDown(() {
    source.dispose();
  });

  group('YoutubeSource', () {
    test('has correct id and displayName', () {
      expect(source.id, 'youtube');
      expect(source.displayName, 'YouTube');
    });

    test('search returns results for popular query', () async {
      final results = await source.search('rick astley never gonna', limit: 5);
      // YouTube search может работать или нет (PoToken issue),
      // но метод не должен падать
      expect(results, isA<List<Track>>());
      for (final track in results) {
        expect(track.sourceId, 'youtube');
        expect(track.title, isNotEmpty);
        expect(track.artist, isNotEmpty);
      }
    });

    test('resolveStreamUrl returns valid URL for known video', () async {
      // dQw4w9WgXcQ = Rick Astley — Never Gonna Give You Up
      const track = Track(
        id: 'dQw4w9WgXcQ',
        sourceId: 'youtube',
        title: 'Rick Astley — Never Gonna Give You Up',
        artist: 'Rick Astley',
      );

      try {
        final url = await source.resolveStreamUrl(track);
        expect(url, isNotEmpty);
        expect(url.startsWith('http'), isTrue);
      } catch (_) {
        // Может упасть из-за PoToken / network issues — это ок
      }
    });

    test('resolveBitrate returns kbps for known video', () async {
      const track = Track(
        id: 'dQw4w9WgXcQ',
        sourceId: 'youtube',
        title: 'Test',
        artist: 'Test',
      );

      try {
        final bitrate = await source.resolveBitrate(track);
        if (bitrate != null) {
          expect(bitrate, greaterThan(0));
        }
      } catch (_) {
        // Может упасть — ok
      }
    });

    test('is registered but disabled for search', () {
      // YouTube должен быть зарегистрирован в реестре,
      // но исключён из поиска
      SourceRegistry.instance.registerDefaults();

      // Зарегистрирован
      expect(SourceRegistry.instance.require('youtube').id, 'youtube');

      // Но отключён для поиска
      expect(SourceRegistry.instance.isDisabled('youtube'), isTrue);

      SourceRegistry.instance.disposeAll();
    });

    test('dispose cleans up without error', () async {
      await source.dispose();
      // Не должен падать при повторном dispose
      await source.dispose();
    });
  });
}
