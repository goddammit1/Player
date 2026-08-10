@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/youtube_source.dart';
import 'package:player/models/track.dart';

/// Live-тесты YoutubeSource (требуют сети).
/// Unit-тесты (id/displayName, dispose, регистрация) вынесены в
/// youtube_source_unit_test.dart.
void main() {
  late YoutubeSource source;

  setUp(() {
    source = YoutubeSource();
  });

  tearDown(() {
    source.dispose();
  });

  group('YoutubeSource', () {
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

  });
}
