import 'package:flutter_test/flutter_test.dart';
import 'package:player/models/track.dart';

void main() {
  group('Track', () {
    test('toMap / fromMap roundtrip (all fields)', () {
      const original = Track(
        id: 'dQw4w9WgXcQ',
        sourceId: 'youtube',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        duration: Duration(minutes: 3, seconds: 33),
        artworkUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg',
        qualityScore: 95,
        qualityLabel: 'HD',
        extra: {'streamUrl': 'https://example.com/stream.mp3'},
      );

      final map = original.toMap();
      final restored = Track.fromMap(map);

      expect(restored.id, original.id);
      expect(restored.sourceId, original.sourceId);
      expect(restored.title, original.title);
      expect(restored.artist, original.artist);
      expect(restored.duration, original.duration);
      expect(restored.artworkUrl, original.artworkUrl);
      expect(restored.qualityScore, original.qualityScore);
      expect(restored.qualityLabel, original.qualityLabel);
      expect(restored.extra, original.extra);
    });

    test('toMap / fromMap roundtrip (minimal fields)', () {
      const original = Track(
        id: 'abc123',
        sourceId: 'muzmo',
        title: 'Song',
        artist: 'Artist',
      );

      final map = original.toMap();
      final restored = Track.fromMap(map);

      expect(restored.id, original.id);
      expect(restored.sourceId, original.sourceId);
      expect(restored.title, original.title);
      expect(restored.artist, original.artist);
      expect(restored.duration, isNull);
      expect(restored.artworkUrl, isNull);
      expect(restored.qualityScore, isNull);
      expect(restored.qualityLabel, isNull);
      expect(restored.extra, isEmpty);
    });

    test('toMap / fromMap with empty extra', () {
      const original = Track(
        id: 't1',
        sourceId: 'soundcloud',
        title: 'Track',
        artist: 'Artist',
        extra: {},
      );
      final map = original.toMap();
      final restored = Track.fromMap(map);
      expect(restored.extra, isEmpty);
    });

    test('globalId format: source_id:id', () {
      const track = Track(
        id: 'videoId', sourceId: 'youtube', title: 'T', artist: 'A',
      );
      expect(track.globalId, 'youtube:videoId');
    });

    test('copyWith updates only specified fields', () {
      const original = Track(
        id: 'id1', sourceId: 'youtube',
        title: 'Original Title', artist: 'Original Artist',
        duration: Duration(seconds: 120),
        artworkUrl: 'https://example.com/art.jpg',
      );
      final updated = original.copyWith(
        title: 'New Title', artist: 'New Artist',
      );
      expect(updated.title, 'New Title');
      expect(updated.artist, 'New Artist');
      expect(updated.id, original.id);
      expect(updated.sourceId, original.sourceId);
      expect(updated.duration, original.duration);
      expect(updated.artworkUrl, original.artworkUrl);
      expect(updated.extra, original.extra);
    });

    test('copyWith preserves null artwork when not specified', () {
      const original = Track(
        id: 'id1', sourceId: 'soundcloud', title: 'T', artist: 'A',
      );
      final updated = original.copyWith(artworkUrl: 'new.jpg');
      expect(updated.artworkUrl, 'new.jpg');
      final same = original.copyWith();
      expect(same.artworkUrl, isNull);
    });

    test('copyWith quality fields are preserved', () {
      const original = Track(
        id: 'id1', sourceId: 'muzmo', title: 'T', artist: 'A',
        qualityScore: 80, qualityLabel: 'SD',
      );
      final updated = original.copyWith(title: 'New');
      expect(updated.qualityScore, 80);
      expect(updated.qualityLabel, 'SD');
    });

    // ---- equality ----
    test('equality by globalId', () {
      const t1 = Track(
        id: 'abc', sourceId: 'youtube', title: 'T1', artist: 'A1',
      );
      const t2 = Track(
        id: 'abc', sourceId: 'youtube', title: 'T2', artist: 'A2',
      );
      expect(t1 == t2, isTrue);
      expect(t1.hashCode, t2.hashCode);
    });

    test('inequality different sourceId', () {
      const t1 = Track(
        id: 'abc', sourceId: 'youtube', title: 'T', artist: 'A',
      );
      const t2 = Track(
        id: 'abc', sourceId: 'soundcloud', title: 'T', artist: 'A',
      );
      expect(t1 == t2, isFalse);
      expect(t1.hashCode, isNot(t2.hashCode));
    });

    test('inequality different id', () {
      const t1 = Track(
        id: 'abc', sourceId: 'youtube', title: 'T', artist: 'A',
      );
      const t2 = Track(
        id: 'def', sourceId: 'youtube', title: 'T', artist: 'A',
      );
      expect(t1 == t2, isFalse);
      expect(t1.hashCode, isNot(t2.hashCode));
    });

    // ---- JSON null safety (fromMap) ----
    test('fromMap handles null duration_ms', () {
      final map = {'id': 'id', 'source_id': 'src', 'title': 'T', 'artist': 'A'};
      final track = Track.fromMap(map);
      expect(track.duration, isNull);
    });

    test('fromMap handles null artwork_url', () {
      final map = {
        'id': 'id', 'source_id': 'src', 'title': 'T', 'artist': 'A',
        'artwork_url': null,
      };
      final track = Track.fromMap(map);
      expect(track.artworkUrl, isNull);
    });

    test('fromMap handles null extra', () {
      final map = {
        'id': 'id', 'source_id': 'src', 'title': 'T', 'artist': 'A',
        'extra': null,
      };
      final track = Track.fromMap(map);
      expect(track.extra, isEmpty);
    });

    // ---- SESSION-01: null-safe + legacy-ключи ----
    group('SESSION-01: fromMap null-safety + legacy keys', () {
      test('null title/artist default to empty string, not crash', () {
        final track = Track.fromMap({
          'id': 'id',
          'source_id': 'src',
          'title': null,
          'artist': null,
        });
        expect(track.title, '');
        expect(track.artist, '');
      });

      test('missing id → empty id (запись невалидна, DAO её пропустит)', () {
        final track = Track.fromMap({'source_id': 'src', 'title': 'T'});
        expect(track.id, isEmpty);
      });

      test('null id does not throw Null is not a subtype of String', () {
        final track = Track.fromMap({
          'id': null,
          'source_id': 'src',
          'title': 'T',
          'artist': 'A',
        });
        expect(track.id, isEmpty);
      });

      test('legacy key track_id used when id missing (мобильный писатель)',
          () {
        final track = Track.fromMap({
          'track_id': 'legacy_id',
          'source_id': 'soulseek',
          'title': 'T',
          'artist': 'A',
        });
        expect(track.id, 'legacy_id');
      });

      test('id preferred over legacy track_id when both present', () {
        final track = Track.fromMap({
          'id': 'new_id',
          'track_id': 'legacy_id',
          'source_id': 'src',
        });
        expect(track.id, 'new_id');
      });

      test('legacy extra_json (JSON string) is decoded into extra', () {
        final track = Track.fromMap({
          'id': 'id',
          'source_id': 'soulseek',
          'title': 'T',
          'artist': 'A',
          'extra_json': '{"cacheKey":"abc","bitrate":320}',
        });
        expect(track.extra['cacheKey'], 'abc');
        expect(track.extra['bitrate'], 320);
      });

      test('legacy extra_json malformed JSON → empty extra, no crash', () {
        final track = Track.fromMap({
          'id': 'id',
          'source_id': 'src',
          'extra_json': '{not valid json',
        });
        expect(track.extra, isEmpty);
      });

      test('full legacy row (mobile writer pre-fix) parses correctly', () {
        // Формат старого PlayerConversions.trackToRow: track_id + extra_json.
        final track = Track.fromMap({
          'track_id': 'res_1_2',
          'source_id': 'soulseek',
          'title': 'Title',
          'artist': 'Artist',
          'duration_ms': 213000,
          'artwork_url': null,
          'quality_score': 320,
          'quality_label': 'MP3 320',
          'track_global_id': 'soulseek:res_1_2',
          'extra_json':
              '{"peerUsername":"peer","remoteFilename":"a.mp3","sizeBytes":5}',
        });
        expect(track.id, 'res_1_2');
        expect(track.sourceId, 'soulseek');
        expect(track.qualityScore, 320);
        expect(track.qualityLabel, 'MP3 320');
        expect(track.duration, const Duration(milliseconds: 213000));
        expect(track.extra['peerUsername'], 'peer');
        expect(track.extra['sizeBytes'], 5);
      });

      test('roundtrip toMap/fromMap preserves soulseek quality fields', () {
        const original = Track(
          id: 'res_9',
          sourceId: 'soulseek',
          title: 'T',
          artist: 'A',
          qualityScore: 1411,
          qualityLabel: 'FLAC 24/96',
          extra: {
            'cacheKey': 'abc123',
            'bitrate': 1411,
            'sampleRate': 96000,
            'bitDepth': 24,
            'extension': 'flac',
          },
        );
        final restored = Track.fromMap(original.toMap());
        expect(restored.qualityScore, 1411);
        expect(restored.qualityLabel, 'FLAC 24/96');
        expect(restored.extra['cacheKey'], 'abc123');
        expect(restored.extra['bitDepth'], 24);
      });

      test('fromMap tolerates double quality_score from JSON', () {
        final track = Track.fromMap({
          'id': 'id',
          'source_id': 'src',
          'quality_score': 320.0,
        });
        expect(track.qualityScore, 320);
      });
    });
  });
}