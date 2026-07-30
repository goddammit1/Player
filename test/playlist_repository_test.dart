import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/playlist_backup.dart';
import 'package:player/core/playlist_repository.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlaylistRepository.instance.resetForTesting();
  });

  group('PlaylistRepository', () {
    test('create returns playlist with trimmed name', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('  My Playlist  ');
      expect(p.name, 'My Playlist');
      expect(PlaylistRepository.instance.current.length, 1);
    });

    test('create uses default name for empty input', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('   ');
      expect(p.name, 'New playlist');
    });

    test('delete removes playlist', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.delete(p.id);
      expect(PlaylistRepository.instance.current, isEmpty);
    });

    test('rename trims name and ignores empty', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.rename(p.id, '  Updated  ');
      expect(PlaylistRepository.instance.current.first.name, 'Updated');

      PlaylistRepository.instance.rename(p.id, '   ');
      expect(PlaylistRepository.instance.current.first.name, 'Updated');
    });

    test('addTrack and removeTrackAt work by index', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const t1 = Track(
        id: '1',
        sourceId: 'youtube',
        title: 'Song 1',
        artist: 'Artist',
      );
      const t2 = Track(
        id: '2',
        sourceId: 'youtube',
        title: 'Song 2',
        artist: 'Artist',
      );

      PlaylistRepository.instance.addTrack(p.id, t1);
      PlaylistRepository.instance.addTrack(p.id, t2);
      expect(PlaylistRepository.instance.current.first.tracks.length, 2);

      PlaylistRepository.instance.removeTrackAt(p.id, 0);
      expect(PlaylistRepository.instance.current.first.tracks.length, 1);
      expect(PlaylistRepository.instance.current.first.tracks.first.id, '2');
    });

    test('reorderTracks moves track', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const t1 = Track(
        id: '1',
        sourceId: 'youtube',
        title: 'Song 1',
        artist: 'Artist',
      );
      const t2 = Track(
        id: '2',
        sourceId: 'youtube',
        title: 'Song 2',
        artist: 'Artist',
      );
      PlaylistRepository.instance.addTrack(p.id, t1);
      PlaylistRepository.instance.addTrack(p.id, t2);

      PlaylistRepository.instance.reorderTracks(p.id, 0, 2);
      expect(PlaylistRepository.instance.current.first.tracks.first.id, '2');
      expect(PlaylistRepository.instance.current.first.tracks.last.id, '1');
    });

    test('importPlaylists adds new playlists', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final existing = PlaylistRepository.instance.create('Existing');

      final incoming = [
        Playlist(
          id: 'imported-1',
          name: 'Imported',
          tracks: const [],
          createdAt: DateTime(2024),
        ),
      ];

      final result = await PlaylistRepository.instance.importPlaylists(
        incoming,
        strategy: ImportStrategy.skip,
      );
      expect(result.added, 1);
      expect(PlaylistRepository.instance.current.length, 2);
      expect(
        PlaylistRepository.instance.current.any((p) => p.id == existing.id),
        isTrue,
      );
    });

    test('importPlaylists replaces existing', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final existing = PlaylistRepository.instance.create('Existing');
      final incoming = [
        Playlist(
          id: existing.id,
          name: 'Replaced',
          tracks: const [],
          createdAt: DateTime(2024),
        ),
      ];

      final result = await PlaylistRepository.instance.importPlaylists(
        incoming,
        strategy: ImportStrategy.replace,
      );
      expect(result.replaced, 1);
      expect(PlaylistRepository.instance.current.first.name, 'Replaced');
    });

    test('importPlaylists keepBoth creates new id', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final existing = PlaylistRepository.instance.create('Existing');
      final incoming = [
        Playlist(
          id: existing.id,
          name: 'Duplicate',
          tracks: const [],
          createdAt: DateTime(2024),
        ),
      ];

      final result = await PlaylistRepository.instance.importPlaylists(
        incoming,
        strategy: ImportStrategy.keepBoth,
      );
      expect(result.added, 1);
      expect(PlaylistRepository.instance.current.length, 2);
      final ids = PlaylistRepository.instance.current.map((p) => p.id).toSet();
      expect(ids.length, 2);
    });
  });

  group('PlaylistBackup', () {
    test('encode/decode roundtrip', () {
      const track = Track(
        id: 't1',
        sourceId: 'youtube',
        title: 'Song',
        artist: 'Artist',
      );
      final playlist = Playlist(
        id: 'p1',
        name: 'My Playlist',
        tracks: const [track],
        createdAt: DateTime(2024, 1, 1),
      );

      final json = PlaylistBackup.encode([playlist]);
      final decoded = PlaylistBackup.decode(json);
      expect(decoded.length, 1);
      expect(decoded.first.id, 'p1');
      expect(decoded.first.tracks.first.id, 't1');
    });

    test('decode throws on invalid JSON', () {
      expect(() => PlaylistBackup.decode('not json'), throwsFormatException);
    });

    test('decode throws on wrong format', () {
      const raw = '{"format": "wrong", "version": 1, "playlists": []}';
      expect(() => PlaylistBackup.decode(raw), throwsFormatException);
    });

    test('decode throws on unsupported version', () {
      const raw =
          '{"format": "player_playlists_backup", "version": 999, "playlists": []}';
      expect(() => PlaylistBackup.decode(raw), throwsFormatException);
    });

    test('decode skips broken playlists but keeps valid', () {
      const raw = '''
      {
        "format": "player_playlists_backup",
        "version": 1,
        "playlists": [
          {"id": "p1", "name": "Valid", "tracks": [], "created_at_ms": 1700000000000},
          {"id": null, "name": null}
        ]
      }
      ''';
      final decoded = PlaylistBackup.decode(raw);
      expect(decoded.length, 1);
      expect(decoded.first.name, 'Valid');
    });
  });
}
