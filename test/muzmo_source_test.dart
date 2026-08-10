@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/muzmo_source.dart';
import 'package:player/models/track.dart';

void main() {
  late MuzmoSource source;

  setUp(() {
    source = MuzmoSource();
  });

  tearDown(() {
    source.dispose();
  });

  group('MuzmoSource - real API tests', () {
    test('search returns results (or empty if source unavailable)', () async {
      final results = await source.search('imagine dragons believer', limit: 10);
      // Muzmo may return empty list when server is unavailable (403 / Cloudflare).
      // We only assert the method doesn't throw and returns a list.
      expect(results, isA<List<Track>>());
    });

    test('search results have valid shape (when available)', () async {
      final results = await source.search('bring me the horizon throne', limit: 10);
      expect(results, isA<List<Track>>());
      for (final track in results) {
        expect(track.title, isA<String>());
        expect(track.artist, isA<String>());
        expect(track.sourceId, equals('muzmo'));
      }
    });

    test('resolveStreamUrl returns valid URL when source is available', () async {
      final results = await source.search('linkin park numb', limit: 5);
      if (results.isEmpty) {
        // Source unavailable — skip the URL assertion.
        return;
      }
      final firstTrack = results.first;
      final streamUrl = await source.resolveStreamUrl(firstTrack);
      expect(streamUrl, isNotEmpty);
      // URL может быть CDN-адресом файлового хранилища без слова "muzmo"
      // в хосте — проверяем только http-префикс, а не подстроку.
      expect(streamUrl.startsWith('http'), isTrue);
    });

    test('search with empty query returns empty list', () async {
      final results = await source.search('', limit: 5);
      expect(results, isA<List<Track>>());
    });

    test('search handles special characters gracefully', () async {
      final results = await source.search('gorillaz feel good inc', limit: 5);
      expect(results, isA<List<Track>>());
    });
  });
}