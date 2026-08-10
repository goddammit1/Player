import 'package:flutter_test/flutter_test.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';

void main() {
  const sampleTrack = Track(
    id: 't1', sourceId: 'youtube',
    title: 'Song', artist: 'Artist',
  );

  group('Playlist', () {
    test('toJson / fromJson roundtrip (with tracks)', () {
      final original = Playlist(
        id: 'p1', name: 'My Playlist',
        tracks: const [sampleTrack],
        coverCustomUrl: '/custom/cover.jpg',
        createdAt: DateTime(2024, 1, 15),
      );

      final json = original.toJson();
      final restored = Playlist.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.coverCustomUrl, original.coverCustomUrl);
      expect(restored.createdAt, original.createdAt);
      expect(restored.tracks.length, 1);
      expect(restored.tracks.first.id, 't1');
      expect(restored.tracks.first.title, 'Song');
    });

    test('copyWith updates name and coverCustomUrl', () {
      final original = Playlist(
        id: 'p3', name: 'Original', tracks: const [],
        createdAt: DateTime(2024),
      );
      final updated = original.copyWith(
        name: 'Renamed',
        coverCustomUrl: '/new/path.jpg',
      );
      expect(updated.name, 'Renamed');
      expect(updated.coverCustomUrl, '/new/path.jpg');
      expect(updated.id, original.id);
      expect(updated.createdAt, original.createdAt);
    });

    test('copyWith updates tracks list', () {
      final original = Playlist(
        id: 'p4', name: 'Test', tracks: const [],
        createdAt: DateTime(2024),
      );
      const newTracks = [sampleTrack];
      final updated = original.copyWith(tracks: newTracks);
      expect(updated.tracks.length, 1);
      expect(updated.tracks.first.id, 't1');
    });

    test('coverThumbnails returns first 4 non-empty artwork URLs', () {
      final playlist = Playlist(
        id: 'p5', name: 'Covers Test', createdAt: DateTime(2024),
        tracks: const [
          Track(id: '1', sourceId: 's', title: 'T1', artist: 'A1',
                artworkUrl: 'url1'),
          Track(id: '2', sourceId: 's', title: 'T2', artist: 'A2',
                artworkUrl: 'url2'),
          Track(id: '3', sourceId: 's', title: 'T3', artist: 'A3',
                artworkUrl: null),
          Track(id: '4', sourceId: 's', title: 'T4', artist: 'A4',
                artworkUrl: 'url4'),
        ],
      );
      final thumbs = playlist.coverThumbnails;
      expect(thumbs.length, 3);
      expect(thumbs, ['url1', 'url2', 'url4']);
    });

    test('coverTrackIds syncs with coverThumbnails', () {
      final playlist = Playlist(
        id: 'p6', name: 'TrackIds Test', createdAt: DateTime(2024),
        tracks: const [
          Track(id: 'a', sourceId: 's', title: 'T1', artist: 'A',
                artworkUrl: 'urlA'),
          Track(id: 'b', sourceId: 's', title: 'T2', artist: 'A'),
          Track(id: 'c', sourceId: 's', title: 'T3', artist: 'A',
                artworkUrl: 'urlC'),
        ],
      );
      final ids = playlist.coverTrackIds;
      expect(ids.length, 2);
      expect(ids, ['a', 'c']);
    });

    test('JSON roundtrip preserves track extra fields', () {
      final playlist = Playlist(
        id: 'p7', name: 'Extra Test', createdAt: DateTime(2024),
        tracks: [
          Track(id: 't1', sourceId: 'muzmo',
                title: 'Song', artist: 'Artist',
                duration: Duration(seconds: 210),
                extra: {'streamUrl': 'https://example.com/stream'},
          ),
        ],
      );

      final json = playlist.toJson();
      final restored = Playlist.fromJson(json);

      expect(restored.tracks.first.duration, Duration(seconds: 210));
      expect(restored.tracks.first.extra['streamUrl'], 'https://example.com/stream');
    });
  });
}

