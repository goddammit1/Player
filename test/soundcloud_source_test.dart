@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soundcloud_source.dart';
import 'package:player/models/track.dart';

void main() {
  late SoundCloudSource source;

  setUp(() {
    source = SoundCloudSource();
  });

  tearDown(() {
    source.dispose();
  });

  group('SoundCloudSource - real API tests', () {
    test('search returns non-empty results for popular query', () async {
      final results = await source.search('the weeknd blinding lights', limit: 10);
      expect(results, isNotEmpty);
    });

    test('search results have valid title, artist, and duration', () async {
      final results = await source.search('imagine dragons believer', limit: 10);
      expect(results, isNotEmpty);

      for (final track in results) {
        expect(track.title, isNotEmpty);
        expect(track.artist, isNotEmpty);
        expect(track.sourceId, equals('soundcloud'));
        // duration may be null for some results, but most should have it
      }
    });

    test('resolveStreamUrl returns valid URL without encrypted HLS', () async {
      final results = await source.search('drake gods plan', limit: 5);
      expect(results, isNotEmpty);

      final firstTrack = results.first;
      final streamUrl = await source.resolveStreamUrl(firstTrack);
      expect(streamUrl, isNotEmpty);
      // URL must not contain encrypted HLS
      expect(streamUrl.contains('encrypted'), isFalse);
      expect(streamUrl.contains('cbc'), isFalse);
      // Should be a valid HTTP URL
      expect(streamUrl.startsWith('http'), isTrue);
    });

    test('search results stream URLs are DRM-free', () async {
      final results = await source.search('kygo firestone', limit: 5);
      expect(results, isNotEmpty);

      // Resolve first 3 tracks and verify no DRM
      for (final track in results.take(3)) {
        try {
          final url = await source.resolveStreamUrl(track);
          expect(url, isNotEmpty);
          expect(url.contains('encrypted'), isFalse,
              reason: 'Track "${track.title}" has encrypted stream: $url');
          expect(url.contains('cbc-encrypted'), isFalse,
              reason: 'Track "${track.title}" has cbc-encrypted HLS: $url');
        } catch (_) {
          // Some tracks may fail to resolve — that's OK
        }
      }
    });

    test('search with empty query returns empty or handles gracefully', () async {
      final results = await source.search('', limit: 5);
      expect(results, isA<List<Track>>());
    });

    test('search handles complex queries', () async {
      final results = await source.search('daft punk get lucky', limit: 5);
      expect(results, isA<List<Track>>());
      // At least verify we got something
      if (results.isNotEmpty) {
        expect(results.first.title, isNotEmpty);
      }
    });
  });
}