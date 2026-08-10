import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/playlist_backup.dart';
import 'package:player/core/playlist_repository.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';

import 'setup/test_harness.dart';

/// Фейковый источник SoundCloud, который умеет восстанавливать обложку
/// по ID трека (как настоящий SoundCloudSource через GET /tracks/{id}).
class _ArtworkRestoreFakeSource extends TrackSource {
  @override
  String get id => 'soundcloud';

  @override
  String get displayName => 'Fake SoundCloud';

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async => const [];

  @override
  Future<String> resolveStreamUrl(Track track) async =>
      'https://example.com/stream.mp3';

  @override
  Future<String?> resolveArtwork(Track track) async =>
      'https://i1.sndcdn.com/artworks-restored-t500x500.jpg';
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async {
    await TestHarness.setUpDb();
    await PlaylistRepository.instance.resetForTesting();
  });

  tearDown(() async {
    await TestHarness.tearDownDb();
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

  group('PlaylistRepository artwork enrichment', () {
    setUp(() => ArtworkProvider.instance.clearMemCache());

    test(
      'resetAllTrackArtworks clears provider urls but keeps source/local paths',
      () async {
        await PlaylistRepository.instance.ensureLoaded();
        final p = PlaylistRepository.instance.create('Test');
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '1',
            sourceId: 'muzmo',
            title: 'Genius',
            artist: 'A',
            artworkUrl: 'https://images.genius.com/genius.jpg',
          ),
        );
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '2',
            sourceId: 'youtube',
            title: 'Local',
            artist: 'B',
            artworkUrl: '/data/user/0/player/custom_artworks/2.jpg',
          ),
        );
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '3',
            sourceId: 'youtube',
            title: 'File',
            artist: 'C',
            artworkUrl: 'file:///data/user/0/player/custom_artworks/3.jpg',
          ),
        );
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '4',
            sourceId: 'soundcloud',
            title: 'Cloud',
            artist: 'D',
            artworkUrl: 'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
          ),
        );
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(id: '5', sourceId: 'youtube', title: 'None', artist: 'E'),
        );

        // Сидим mem-cache ДО сброса: запущенный сбросом enrichment вернёт
        // findArtwork мгновенно, без реальных запросов в сеть. Пустая строка —
        // отрицательный кэш: трек останется без обложки.
        ArtworkProvider.instance.cacheArtworkForTesting(
          'A',
          'Genius',
          'https://images.genius.com/genius-new.jpg',
        );
        ArtworkProvider.instance.cacheArtworkForTesting('E', 'None', '');

        PlaylistRepository.instance.resetAllTrackArtworks();

        // Сброс обнуляет только провайдерские (Genius/iTunes) URL;
        // обложки источника (sndcdn) и локальные пути остаются.
        var tracks = PlaylistRepository.instance.current.first.tracks;
        expect(tracks[0].artworkUrl, isNull);
        expect(
          tracks[1].artworkUrl,
          '/data/user/0/player/custom_artworks/2.jpg',
        );
        expect(
          tracks[2].artworkUrl,
          'file:///data/user/0/player/custom_artworks/3.jpg',
        );
        expect(
          tracks[3].artworkUrl,
          'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        );
        expect(tracks[4].artworkUrl, isNull);

        // Сброс сам запустил фоновую дозагрузку: Genius перезапрошен,
        // None остаётся без обложки, sndcdn/локальные пути не тронуты.
        await PlaylistRepository.instance.flushEnrichmentForTesting();

        tracks = PlaylistRepository.instance.current.first.tracks;
        expect(
          tracks[0].artworkUrl,
          'https://images.genius.com/genius-new.jpg',
        );
        expect(
          tracks[1].artworkUrl,
          '/data/user/0/player/custom_artworks/2.jpg',
        );
        expect(
          tracks[2].artworkUrl,
          'file:///data/user/0/player/custom_artworks/3.jpg',
        );
        expect(
          tracks[3].artworkUrl,
          'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        );
        expect(tracks[4].artworkUrl, isNull);
      },
    );

    test('resetAllTrackArtworks does not emit when nothing to reset', () async {
      await PlaylistRepository.instance.ensureLoaded();
      PlaylistRepository.instance.create('Test');
      final emits = <int>[];
      final sub = PlaylistRepository.instance.stream.listen(
        (l) => emits.add(l.length),
      );
      PlaylistRepository.instance.resetAllTrackArtworks();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emits, isEmpty);
      await sub.cancel();
    });

    test('updateTrackArtwork updates the track in all playlists', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p1 = PlaylistRepository.instance.create('P1');
      final p2 = PlaylistRepository.instance.create('P2');
      const t = Track(
        id: '1',
        sourceId: 'youtube',
        title: 'Song',
        artist: 'Artist',
      );
      PlaylistRepository.instance.addTrack(p1.id, t);
      PlaylistRepository.instance.addTrack(p2.id, t);

      PlaylistRepository.instance.updateTrackArtwork(
        t.globalId,
        'http://example.com/art.jpg',
      );

      final allUpdated = PlaylistRepository.instance.current.every(
        (p) => p.tracks.every(
          (tr) => tr.artworkUrl == 'http://example.com/art.jpg',
        ),
      );
      expect(allUpdated, isTrue);
    });

    test('updateTrackArtwork with same url does not emit', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const t = Track(
        id: '1',
        sourceId: 'youtube',
        title: 'Song',
        artist: 'Artist',
        artworkUrl: 'http://example.com/art.jpg',
      );
      PlaylistRepository.instance.addTrack(p.id, t);

      final emits = <int>[];
      final sub = PlaylistRepository.instance.stream.listen(
        (l) => emits.add(l.length),
      );
      PlaylistRepository.instance.updateTrackArtwork(
        t.globalId,
        'http://example.com/art.jpg',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emits, isEmpty);
      await sub.cancel();
    });

    test('enrichment fills missing artwork and batches stream emits', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const t1 = Track(
        id: '1',
        sourceId: 'youtube',
        title: 'Song One',
        artist: 'Artist',
      );
      const t2 = Track(
        id: '2',
        sourceId: 'youtube',
        title: 'Song Two',
        artist: 'Artist',
      );
      PlaylistRepository.instance.addTrack(p.id, t1);
      PlaylistRepository.instance.addTrack(p.id, t2);
      await PlaylistRepository.instance.flush();

      // Сид in-memory кэша ArtworkProvider — findArtwork вернёт их без сети.
      ArtworkProvider.instance.cacheArtworkForTesting(
        'Artist',
        'Song One',
        'http://example.com/one.jpg',
      );
      ArtworkProvider.instance.cacheArtworkForTesting(
        'Artist',
        'Song Two',
        'http://example.com/two.jpg',
      );

      await PlaylistRepository.instance.reload();

      // Подписка после reload: единственный emit, который прилетит, — батч.
      final emits = <List<Playlist>>[];
      final sub = PlaylistRepository.instance.stream.listen(emits.add);

      await PlaylistRepository.instance.flushEnrichmentForTesting();

      // Broadcast-контроллер создан с sync: false — события доставляются
      // слушателю асинхронно. Даём доставке дойти до проверки.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        emits.length,
        1,
        reason: 'вся пачка обложек применяется одним эмитом',
      );
      final tracks = PlaylistRepository.instance.current.first.tracks;
      expect(tracks[0].artworkUrl, 'http://example.com/one.jpg');
      expect(tracks[1].artworkUrl, 'http://example.com/two.jpg');
      await sub.cancel();
    });

    test('enrichment skips tracks with empty artist/title', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.addTrack(
        p.id,
        const Track(id: '1', sourceId: 'youtube', title: 'Song', artist: '   '),
      );
      PlaylistRepository.instance.addTrack(
        p.id,
        const Track(
          id: '2',
          sourceId: 'youtube',
          title: 'Song Two',
          artist: 'Artist',
        ),
      );
      await PlaylistRepository.instance.flush();

      ArtworkProvider.instance.cacheArtworkForTesting(
        'Artist',
        'Song Two',
        'http://example.com/two.jpg',
      );

      await PlaylistRepository.instance.reload();
      await PlaylistRepository.instance.flushEnrichmentForTesting();

      final tracks = PlaylistRepository.instance.current.first.tracks;
      expect(
        tracks[0].artworkUrl,
        isNull,
        reason: 'пустой artist пропускается',
      );
      expect(tracks[1].artworkUrl, 'http://example.com/two.jpg');
    });

    test(
      'resetAllTrackArtworks restarts enrichment and re-fills artwork',
      () async {
        await PlaylistRepository.instance.ensureLoaded();
        final p = PlaylistRepository.instance.create('Test');
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '1',
            sourceId: 'muzmo',
            title: 'Song Reset',
            artist: 'Artist',
            artworkUrl: 'https://images.genius.com/old.jpg',
          ),
        );

        // Сид in-memory кэша ArtworkProvider ДО сброса — findArtwork вернёт
        // URL мгновенно, без сети.
        ArtworkProvider.instance.cacheArtworkForTesting(
          'Artist',
          'Song Reset',
          'https://images.genius.com/new.jpg',
        );

        // Сброс обнуляет провайдерский URL и сам запускает фоновую дозагрузку.
        PlaylistRepository.instance.resetAllTrackArtworks();
        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          isNull,
          reason: 'провайдерский URL обнулён сразу после сброса',
        );

        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://images.genius.com/new.jpg',
          reason:
              'обложка перезапрошена после сброса без ручного воспроизведения',
        );
      },
    );

    test('enrichment caps batch at 50 tracks per load', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const n = 52;

      for (var i = 0; i < n; i++) {
        PlaylistRepository.instance.addTrack(
          p.id,
          Track(
            id: '$i',
            sourceId: 'youtube',
            title: 'Song $i',
            artist: 'Artist',
          ),
        );
        ArtworkProvider.instance.cacheArtworkForTesting(
          'Artist',
          'Song $i',
          'http://example.com/art_$i.jpg',
        );
      }
      await PlaylistRepository.instance.flush();

      await PlaylistRepository.instance.reload();
      await PlaylistRepository.instance.flushEnrichmentForTesting();

      final tracks = PlaylistRepository.instance.current.first.tracks;
      final withArt = tracks.where((t) => t.artworkUrl != null).length;
      expect(
        withArt,
        50,
        reason: 'за один load обогащается не более 50 треков',
      );
    });
    test('resetAllTrackArtworks keeps soundcloud source artwork', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.addTrack(
        p.id,
        const Track(
          id: 'sc1',
          sourceId: 'soundcloud',
          title: 'SC Track',
          artist: 'SC Artist',
          artworkUrl: 'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        ),
      );

      // Даже если Genius/iTunes ничего не знают про трек, сброс не должен
      // стирать «родную» обложку SoundCloud — она стабильна и после
      // очистки дискового кэша перекачается по тому же URL.
      PlaylistRepository.instance.resetAllTrackArtworks();

      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        reason: 'обложка источника (sndcdn.com) не сбрасывается',
      );

      // Enrichment тоже не должен трогать трек с уже заполненным URL.
      await PlaylistRepository.instance.flushEnrichmentForTesting();
      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
      );
    });

    test(
      'enrichment restores lost artwork from the source when Genius has none',
      () async {
        SourceRegistry.instance.register(_ArtworkRestoreFakeSource());
        addTearDown(() => SourceRegistry.instance.disposeAll());

        await PlaylistRepository.instance.ensureLoaded();
        final p = PlaylistRepository.instance.create('Test');
        // artworkUrl потерян — его стёрла очистка кэша обложек в старой
        // версии и сохранила null в БД. Genius/iTunes такую обложку не знают,
        // поэтому восстановить её может только сам источник по ID трека.
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: 'sc1',
            sourceId: 'soundcloud',
            title: 'SC Track',
            artist: 'SC Artist',
          ),
        );
        await PlaylistRepository.instance.flush();
        // reload запускает волну обогащения для треков без обложек.
        await PlaylistRepository.instance.reload();

        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://i1.sndcdn.com/artworks-restored-t500x500.jpg',
          reason:
              'обложка восстановлена из источника (SoundCloud), '
              'а не из Genius/iTunes',
        );
      },
    );
  });
}
