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
  });
}