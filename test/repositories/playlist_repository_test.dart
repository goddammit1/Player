import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/artwork_helper.dart';
import 'package:player/core/repositories/history_repository.dart';
import 'package:player/core/backup/playlist_backup.dart';
import 'package:player/core/repositories/playlist_repository.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';

import '../setup/test_harness.dart';

/// Р¤РµР№РєРѕРІС‹Р№ РёСЃС‚РѕС‡РЅРёРє SoundCloud, РєРѕС‚РѕСЂС‹Р№ СѓРјРµРµС‚ РІРѕСЃСЃС‚Р°РЅР°РІР»РёРІР°С‚СЊ РѕР±Р»РѕР¶РєСѓ
/// РїРѕ ID С‚СЂРµРєР° (РєР°Рє РЅР°СЃС‚РѕСЏС‰РёР№ SoundCloudSource С‡РµСЂРµР· GET /tracks/{id}).
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

  group('PlaylistRepository - manual order persistence', () {
    test('reorderTracks order survives flush + reload (DB roundtrip)',
        () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Manual');
      const t1 = Track(
        id: '1', sourceId: 'youtube', title: 'Alpha', artist: 'A');
      const t2 = Track(
        id: '2', sourceId: 'youtube', title: 'Beta', artist: 'B');
      const t3 = Track(
        id: '3', sourceId: 'youtube', title: 'Gamma', artist: 'C');
      PlaylistRepository.instance.addTrack(p.id, t1);
      PlaylistRepository.instance.addTrack(p.id, t2);
      PlaylistRepository.instance.addTrack(p.id, t3);

      // Переставляем: последний трек переезжает в начало (0 → 3).
      PlaylistRepository.instance.reorderTracks(p.id, 2, 0);
      expect(
        PlaylistRepository.instance.current.first.tracks.map((t) => t.id),
        ['3', '1', '2'],
      );

      // Флаш на диск, сбрасываем память и перечитываем с диска.
      await PlaylistRepository.instance.flush();
      await PlaylistRepository.instance.reload();

      expect(
        PlaylistRepository.instance.current.first.tracks.map((t) => t.id),
        ['3', '1', '2'],
      );
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
      'resetAllTrackArtworks clears provider urls and dead custom-art paths, '
      'keeps live ones and source artwork',
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
        // РўСЂРµРє 5: В«РјС‘СЂС‚РІР°СЏВ» СЃСЃС‹Р»РєР° РЅР° РєР°СЃС‚РѕРјРЅСѓСЋ РѕР±Р»РѕР¶РєСѓ вЂ” С„Р°Р№Р» СѓРґР°Р»С‘РЅ
        // (В«Clear all cacheВ»), РІ RAM-РєСЌС€Рµ ArtworkHelper РµС‘ С‚РѕР¶Рµ РЅРµС‚.
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '5',
            sourceId: 'youtube',
            title: 'DeadCustom',
            artist: 'E',
            artworkUrl: '/data/user/0/player/custom_artworks/5.jpg',
          ),
        );
        // РўСЂРµРє 6: В«Р¶РёРІР°СЏВ» РєР°СЃС‚РѕРјРЅР°СЏ РѕР±Р»РѕР¶РєР° вЂ” С„Р°Р№Р» РЅР° РґРёСЃРєРµ СЃСѓС‰РµСЃС‚РІСѓРµС‚,
        // РµС‘ РїСѓС‚СЊ Р»РµР¶РёС‚ РІ RAM-РєСЌС€Рµ ArtworkHelper (РєР°Рє РїРѕСЃР»Рµ pickAndSaveArtwork).
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: '6',
            sourceId: 'youtube',
            title: 'LiveCustom',
            artist: 'F',
            artworkUrl: '/data/user/0/player/custom_artworks/6.jpg',
          ),
        );

        // РЎРёРґРёРј mem-cache Р”Рћ СЃР±СЂРѕСЃР°: Р·Р°РїСѓС‰РµРЅРЅС‹Р№ СЃР±СЂРѕСЃРѕРј enrichment РІРµСЂРЅС‘С‚
        // findArtwork РјРіРЅРѕРІРµРЅРЅРѕ, Р±РµР· СЂРµР°Р»СЊРЅС‹С… Р·Р°РїСЂРѕСЃРѕРІ РІ СЃРµС‚СЊ. РџСѓСЃС‚Р°СЏ СЃС‚СЂРѕРєР° вЂ”
        // РѕС‚СЂРёС†Р°С‚РµР»СЊРЅС‹Р№ РєСЌС€: С‚СЂРµРє РѕСЃС‚Р°РЅРµС‚СЃСЏ Р±РµР· РѕР±Р»РѕР¶РєРё.
        ArtworkProvider.instance.cacheArtworkForTesting(
          'A',
          'Genius',
          'https://images.genius.com/genius-new.jpg',
        );
        // РўСЂРµРєРё 2 Рё 3 (Local/File) С‚РѕР¶Рµ СЃС‚Р°РЅСѓС‚ РєР°РЅРґРёРґР°С‚Р°РјРё РїРѕСЃР»Рµ СЃР±СЂРѕСЃР°
        // РјС‘СЂС‚РІС‹С… РєР°СЃС‚РѕРјРЅС‹С… РїСѓС‚РµР№ вЂ” СЃРёРґРёРј РєСЌС€, С‡С‚РѕР±С‹ РїРµСЂРµР·Р°РїСЂРѕСЃ Р·Р°РІРµСЂС€РёР»СЃСЏ
        // РјРіРЅРѕРІРµРЅРЅРѕ Рё Р·Р°РјРµРЅРёР» Р±РёС‚С‹Р№ Р»РѕРєР°Р»СЊРЅС‹Р№ РїСѓС‚СЊ РЅР° РѕСЂРёРіРёРЅР°Р»СЊРЅС‹Р№ URL.
        ArtworkProvider.instance.cacheArtworkForTesting(
          'B',
          'Local',
          'https://images.genius.com/local-restored.jpg',
        );
        ArtworkProvider.instance.cacheArtworkForTesting(
          'C',
          'File',
          'https://images.genius.com/file-restored.jpg',
        );
        ArtworkProvider.instance.cacheArtworkForTesting(
          'E',
          'DeadCustom',
          'https://images.genius.com/dead-custom-restored.jpg',
        );
        ArtworkProvider.instance.cacheArtworkForTesting('F', 'LiveCustom', '');

        // В«Р–РёРІР°СЏВ» РєР°СЃС‚РѕРјРЅР°СЏ РѕР±Р»РѕР¶РєР°: СЂРµР°Р»СЊРЅС‹Р№ С„Р°Р№Р» РІ docsDir + Р·Р°РїРёСЃСЊ РІ Р‘Р” +
        // init() вЂ” СЂРѕРІРЅРѕ РєР°Рє pickAndSaveArtwork. РўРѕРіРґР° getCustomArtworkSync
        // РІРµСЂРЅС‘С‚ РїСѓС‚СЊ, Рё resetAllTrackArtworks РЅРµ РґРѕР»Р¶РµРЅ РµС‘ СЃР±СЂР°СЃС‹РІР°С‚СЊ.
        ArtworkHelper.resetInit();
        final docsDir = Directory.systemTemp.createTempSync('custom_art_docs_');
        addTearDown(() {
          ArtworkHelper.setDocsDirForTesting(null);
          try {
            docsDir.deleteSync(recursive: true);
          } catch (_) {}
        });
        // ignore: invalid_use_of_visible_for_testing_member
        ArtworkHelper.setDocsDirForTesting(docsDir);
        final liveDir = Directory('${docsDir.path}/custom_artworks');
        liveDir.createSync(recursive: true);
        // РџСѓС‚СЊ В«РєР°Рє РµРіРѕ РІРёРґРёС‚ init()В»: Р±РµСЂС‘Рј РёР· listSync (РЅР° Windows РѕРЅ
        // СЃРѕРґРµСЂР¶РёС‚ РЅР°С‚РёРІРЅС‹Р№ СЂР°Р·РґРµР»РёС‚РµР»СЊ, Р° p.join/File.path вЂ” РЅРµС‚).
        final liveFile = File('${liveDir.path}/6.jpg');
        await liveFile.writeAsString('img');
        final livePath = liveDir
            .listSync()
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('6.jpg'))
            .path;
        await AppDatabase.instance.setCustomArtworkPath('6', livePath);
        await ArtworkHelper.init();
        // Р›РµРЅРёРІР°СЏ РїРѕРґРіСЂСѓР·РєР° РїРѕ Р·Р°РїСЂРѕСЃСѓ вЂ” init() RAM-РєСЌС€ РЅРµ РЅР°РїРѕР»РЅСЏРµС‚.
        await ArtworkHelper.getCustomArtwork('6');
        expect(ArtworkHelper.getCustomArtworkSync('6'), livePath);

        PlaylistRepository.instance.resetAllTrackArtworks();

        // РЎР±СЂРѕСЃ РѕР±РЅСѓР»СЏРµС‚ РїСЂРѕРІР°Р№РґРµСЂСЃРєРёРµ (Genius/iTunes) URL Рё В«РјС‘СЂС‚РІС‹РµВ»
        // СЃСЃС‹Р»РєРё РЅР° СѓРґР°Р»С‘РЅРЅС‹Рµ РєР°СЃС‚РѕРјРЅС‹Рµ РѕР±Р»РѕР¶РєРё; В«Р¶РёРІР°СЏВ» РєР°СЃС‚РѕРјРЅР°СЏ РѕР±Р»РѕР¶РєР°
        // Рё СЂРѕРґРЅР°СЏ РѕР±Р»РѕР¶РєР° РёСЃС‚РѕС‡РЅРёРєР° (sndcdn) СЃРѕС…СЂР°РЅСЏСЋС‚СЃСЏ.
        var tracks = PlaylistRepository.instance.current.first.tracks;
        expect(tracks[0].artworkUrl, isNull);
        expect(tracks[1].artworkUrl, isNull);
        expect(tracks[2].artworkUrl, isNull);
        expect(
          tracks[3].artworkUrl,
          'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        );
        expect(tracks[4].artworkUrl, isNull);
        expect(
          tracks[5].artworkUrl,
          '/data/user/0/player/custom_artworks/6.jpg',
        );

        // РЎР±СЂРѕСЃ СЃР°Рј Р·Р°РїСѓСЃС‚РёР» С„РѕРЅРѕРІСѓСЋ РґРѕР·Р°РіСЂСѓР·РєСѓ: Genius РїРµСЂРµР·Р°РїСЂРѕС€РµРЅ,
        // В«РјС‘СЂС‚РІС‹Р№В» РєР°СЃС‚РѕРјРЅС‹Р№ РїСѓС‚СЊ РїРµСЂРµР·Р°РїСЂРѕС€РµРЅ Рё Р·Р°РјРµРЅС‘РЅ РЅР° РѕСЂРёРіРёРЅР°Р»СЊРЅСѓСЋ
        // РѕР±Р»РѕР¶РєСѓ (restored), sndcdn Рё Р¶РёРІРѕР№ РєР°СЃС‚РѕРј РЅРµ С‚СЂРѕРЅСѓС‚С‹.
        await PlaylistRepository.instance.flushEnrichmentForTesting();

        tracks = PlaylistRepository.instance.current.first.tracks;
        expect(
          tracks[0].artworkUrl,
          'https://images.genius.com/genius-new.jpg',
        );
        expect(
          tracks[1].artworkUrl,
          'https://images.genius.com/local-restored.jpg',
        );
        expect(
          tracks[2].artworkUrl,
          'https://images.genius.com/file-restored.jpg',
        );
        expect(
          tracks[3].artworkUrl,
          'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        );
        expect(
          tracks[4].artworkUrl,
          'https://images.genius.com/dead-custom-restored.jpg',
        );
        expect(
          tracks[5].artworkUrl,
          '/data/user/0/player/custom_artworks/6.jpg',
        );
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

      // РЎРёРґ in-memory РєСЌС€Р° ArtworkProvider вЂ” findArtwork РІРµСЂРЅС‘С‚ РёС… Р±РµР· СЃРµС‚Рё.
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

      // РџРѕРґРїРёСЃРєР° РїРѕСЃР»Рµ reload: РµРґРёРЅСЃС‚РІРµРЅРЅС‹Р№ emit, РєРѕС‚РѕСЂС‹Р№ РїСЂРёР»РµС‚РёС‚, вЂ” Р±Р°С‚С‡.
      final emits = <List<Playlist>>[];
      final sub = PlaylistRepository.instance.stream.listen(emits.add);

      await PlaylistRepository.instance.flushEnrichmentForTesting();

      // Broadcast-РєРѕРЅС‚СЂРѕР»Р»РµСЂ СЃРѕР·РґР°РЅ СЃ sync: false вЂ” СЃРѕР±С‹С‚РёСЏ РґРѕСЃС‚Р°РІР»СЏСЋС‚СЃСЏ
      // СЃР»СѓС€Р°С‚РµР»СЋ Р°СЃРёРЅС…СЂРѕРЅРЅРѕ. Р”Р°С‘Рј РґРѕСЃС‚Р°РІРєРµ РґРѕР№С‚Рё РґРѕ РїСЂРѕРІРµСЂРєРё.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        emits.length,
        1,
        reason: 'РІСЃСЏ РїР°С‡РєР° РѕР±Р»РѕР¶РµРє РїСЂРёРјРµРЅСЏРµС‚СЃСЏ РѕРґРЅРёРј СЌРјРёС‚РѕРј',
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
        reason: 'РїСѓСЃС‚РѕР№ artist РїСЂРѕРїСѓСЃРєР°РµС‚СЃСЏ',
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

        // РЎРёРґ in-memory РєСЌС€Р° ArtworkProvider Р”Рћ СЃР±СЂРѕСЃР° вЂ” findArtwork РІРµСЂРЅС‘С‚
        // URL РјРіРЅРѕРІРµРЅРЅРѕ, Р±РµР· СЃРµС‚Рё.
        ArtworkProvider.instance.cacheArtworkForTesting(
          'Artist',
          'Song Reset',
          'https://images.genius.com/new.jpg',
        );

        // РЎР±СЂРѕСЃ РѕР±РЅСѓР»СЏРµС‚ РїСЂРѕРІР°Р№РґРµСЂСЃРєРёР№ URL Рё СЃР°Рј Р·Р°РїСѓСЃРєР°РµС‚ С„РѕРЅРѕРІСѓСЋ РґРѕР·Р°РіСЂСѓР·РєСѓ.
        PlaylistRepository.instance.resetAllTrackArtworks();
        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          isNull,
          reason: 'РїСЂРѕРІР°Р№РґРµСЂСЃРєРёР№ URL РѕР±РЅСѓР»С‘РЅ СЃСЂР°Р·Сѓ РїРѕСЃР»Рµ СЃР±СЂРѕСЃР°',
        );

        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://images.genius.com/new.jpg',
          reason:
              'РѕР±Р»РѕР¶РєР° РїРµСЂРµР·Р°РїСЂРѕС€РµРЅР° РїРѕСЃР»Рµ СЃР±СЂРѕСЃР° Р±РµР· СЂСѓС‡РЅРѕРіРѕ РІРѕСЃРїСЂРѕРёР·РІРµРґРµРЅРёСЏ',
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
        reason: 'Р·Р° РѕРґРёРЅ load РѕР±РѕРіР°С‰Р°РµС‚СЃСЏ РЅРµ Р±РѕР»РµРµ 50 С‚СЂРµРєРѕРІ',
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

      // Р”Р°Р¶Рµ РµСЃР»Рё Genius/iTunes РЅРёС‡РµРіРѕ РЅРµ Р·РЅР°СЋС‚ РїСЂРѕ С‚СЂРµРє, СЃР±СЂРѕСЃ РЅРµ РґРѕР»Р¶РµРЅ
      // СЃС‚РёСЂР°С‚СЊ В«СЂРѕРґРЅСѓСЋВ» РѕР±Р»РѕР¶РєСѓ SoundCloud вЂ” РѕРЅР° СЃС‚Р°Р±РёР»СЊРЅР° Рё РїРѕСЃР»Рµ
      // РѕС‡РёСЃС‚РєРё РґРёСЃРєРѕРІРѕРіРѕ РєСЌС€Р° РїРµСЂРµРєР°С‡Р°РµС‚СЃСЏ РїРѕ С‚РѕРјСѓ Р¶Рµ URL.
      PlaylistRepository.instance.resetAllTrackArtworks();

      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        reason: 'РѕР±Р»РѕР¶РєР° РёСЃС‚РѕС‡РЅРёРєР° (sndcdn.com) РЅРµ СЃР±СЂР°СЃС‹РІР°РµС‚СЃСЏ',
      );

      // Enrichment С‚РѕР¶Рµ РЅРµ РґРѕР»Р¶РµРЅ С‚СЂРѕРіР°С‚СЊ С‚СЂРµРє СЃ СѓР¶Рµ Р·Р°РїРѕР»РЅРµРЅРЅС‹Рј URL.
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
        // artworkUrl РїРѕС‚РµСЂСЏРЅ вЂ” РµРіРѕ СЃС‚С‘СЂР»Р° РѕС‡РёСЃС‚РєР° РєСЌС€Р° РѕР±Р»РѕР¶РµРє РІ СЃС‚Р°СЂРѕР№
        // РІРµСЂСЃРёРё Рё СЃРѕС…СЂР°РЅРёР»Р° null РІ Р‘Р”. Genius/iTunes С‚Р°РєСѓСЋ РѕР±Р»РѕР¶РєСѓ РЅРµ Р·РЅР°СЋС‚,
        // РїРѕСЌС‚РѕРјСѓ РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ РµС‘ РјРѕР¶РµС‚ С‚РѕР»СЊРєРѕ СЃР°Рј РёСЃС‚РѕС‡РЅРёРє РїРѕ ID С‚СЂРµРєР°.
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
        // reload Р·Р°РїСѓСЃРєР°РµС‚ РІРѕР»РЅСѓ РѕР±РѕРіР°С‰РµРЅРёСЏ РґР»СЏ С‚СЂРµРєРѕРІ Р±РµР· РѕР±Р»РѕР¶РµРє.
        await PlaylistRepository.instance.reload();

        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://i1.sndcdn.com/artworks-restored-t500x500.jpg',
          reason:
              'РѕР±Р»РѕР¶РєР° РІРѕСЃСЃС‚Р°РЅРѕРІР»РµРЅР° РёР· РёСЃС‚РѕС‡РЅРёРєР° (SoundCloud), '
              'Р° РЅРµ РёР· Genius/iTunes',
        );
      },
    );

    test(
      'refreshArtworkCandidates Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РѕР±РЅРѕРІР»СЏРµС‚ РїСЂРѕСЃСЂРѕС‡РµРЅРЅС‹Р№ TTL-URL '
      'РїСЂРѕРІР°Р№РґРµСЂСЃРєРѕР№ РѕР±Р»РѕР¶РєРё РїСЂРё reload (Р±РµР· СЂСѓС‡РЅРѕР№ РѕС‡РёСЃС‚РєРё РєСЌС€Р°)',
      () async {
        await PlaylistRepository.instance.ensureLoaded();
        final p = PlaylistRepository.instance.create('Test');
        // РўСЂРµРє СЃ РџР РћР’РђР™Р”Р•Р РЎРљРћР™ РѕР±Р»РѕР¶РєРѕР№ (Genius), Сѓ РєРѕС‚РѕСЂРѕР№ В«РїСЂРѕС‚СѓС…В» TTL.
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: 'g1',
            sourceId: 'muzmo',
            title: 'Song',
            artist: 'Artist',
            artworkUrl: 'https://images.genius.com/old_600x600.png',
          ),
        );
        await PlaylistRepository.instance.flush();

        // Р’ РєСЌС€Рµ ArtworkProvider Р»РµР¶РёС‚ РўРћРў Р–Р• URL, РЅРѕ СЃ РїСЂРѕСЃСЂРѕС‡РµРЅРЅС‹Рј TTL.
        final old = DateTime.now().subtract(
          ArtworkProvider.foundUrlTtl + const Duration(days: 1),
        );
        await ArtworkProvider.instance.cacheArtworkToDbForTesting(
          'Artist',
          'Song',
          'https://images.genius.com/old_600x600.png',
          old,
        );

        // Genius С‚РµРїРµСЂСЊ РІРµСЂРЅС‘С‚ РќРћР’РЈР® РѕР±Р»РѕР¶РєСѓ.
        ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async =>
            'https://images.genius.com/new_600x600.png';
        ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
            null;

        // reload() Р·Р°РїСѓСЃРєР°РµС‚ _refreshArtworkCandidates Р±РµР· force в†’
        // РїСЂРѕСЃСЂРѕС‡РµРЅРЅС‹Р№ РїСЂРѕРІР°Р№РґРµСЂСЃРєРёР№ URL РїРµСЂРµР·Р°РїСЂР°С€РёРІР°РµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё.
        await PlaylistRepository.instance.reload();
        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://images.genius.com/new_600x600.png',
          reason:
              'РїРѕСЃР»Рµ РёСЃС‚РµС‡РµРЅРёСЏ TTL РѕР±Р»РѕР¶РєР° Genius РїРµСЂРµР·Р°РїСЂРѕС€РµРЅР° Рё РѕР±РЅРѕРІР»РµРЅР° '
              'РІ РїР»РµР№Р»РёСЃС‚Рµ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё',
        );
      },
    );

    test(
      'refreshArtworkCandidates РќР• РґС‘СЂРіР°РµС‚ СЃРµС‚СЊ РґР»СЏ СЃРІРµР¶РёС… РїСЂРѕРІР°Р№РґРµСЂСЃРєРёС… URL',
      () async {
        await PlaylistRepository.instance.ensureLoaded();
        final p = PlaylistRepository.instance.create('Test');
        PlaylistRepository.instance.addTrack(
          p.id,
          const Track(
            id: 'g2',
            sourceId: 'muzmo',
            title: 'FreshSong',
            artist: 'FreshArtist',
            artworkUrl: 'https://images.genius.com/fresh_600x600.png',
          ),
        );
        await PlaylistRepository.instance.flush();

        // РЎРІРµР¶Р°СЏ Р·Р°РїРёСЃСЊ РІ РєСЌС€Рµ вЂ” TTL РЅРµ РёСЃС‚С‘Рє.
        await ArtworkProvider.instance.cacheArtworkToDbForTesting(
          'FreshArtist',
          'FreshSong',
          'https://images.genius.com/fresh_600x600.png',
          DateTime.now(),
        );
        await PlaylistRepository.instance.flush();

        // РЎРµС‚СЊ РЅРµ РґРѕР»Р¶РЅР° РІС‹Р·С‹РІР°С‚СЊСЃСЏ.
        ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for fresh URL');
        };
        ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for fresh URL');
        };

        await PlaylistRepository.instance.reload();
        await PlaylistRepository.instance.flushEnrichmentForTesting();

        expect(
          PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
          'https://images.genius.com/fresh_600x600.png',
          reason: 'СЃРІРµР¶РёР№ РїСЂРѕРІР°Р№РґРµСЂСЃРєРёР№ URL РЅРµ РїРµСЂРµР·Р°РїСЂР°С€РёРІР°РµС‚СЃСЏ',
        );
      },
    );

    test('РЅР°Р№РґРµРЅРЅС‹Р№ РїР»РµР№Р»РёСЃС‚РѕРј URL РїСЂРѕРїР°РіРёСЂСѓРµС‚СЃСЏ РІ РёСЃС‚РѕСЂРёСЋ', () async {
      await PlaylistRepository.instance.ensureLoaded();
      final p = PlaylistRepository.instance.create('Test');
      const shared = Track(
        id: 'c1',
        sourceId: 'muzmo',
        title: 'CrossSong',
        artist: 'CrossArtist',
      );
      PlaylistRepository.instance.addTrack(p.id, shared);
      // РўР° Р¶Рµ Р·Р°РїРёСЃСЊ (РїРѕ globalId) РµСЃС‚СЊ Рё РІ РёСЃС‚РѕСЂРёРё.
      await HistoryRepository.instance.add(shared);
      await PlaylistRepository.instance.flush();

      ArtworkProvider.instance.cacheArtworkForTesting(
        'CrossArtist',
        'CrossSong',
        'https://images.genius.com/cross.jpg',
      );

      await PlaylistRepository.instance.reload();
      await PlaylistRepository.instance.flushEnrichmentForTesting();

      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        'https://images.genius.com/cross.jpg',
        reason: 'РїР»РµР№Р»РёСЃС‚ РїРѕР»СѓС‡РёР» РѕР±Р»РѕР¶РєСѓ С‡РµСЂРµР· РѕР±РѕРіР°С‰РµРЅРёРµ',
      );
      expect(
        HistoryRepository.instance
            .current
            .firstWhere((e) => e.track.globalId == 'muzmo:c1')
            .track
            .artworkUrl,
        'https://images.genius.com/cross.jpg',
        reason:
            'РѕР±Р»РѕР¶РєР°, РЅР°Р№РґРµРЅРЅР°СЏ РїР»РµР№Р»РёСЃС‚РѕРј, РїСЂРёРјРµРЅРёР»Р°СЃСЊ Рё Рє РёСЃС‚РѕСЂРёРё вЂ” '
            'РІ РїСЂРёР»РѕР¶РµРЅРёРё РІРµР·РґРµ РѕРґРЅР° Рё С‚Р° Р¶Рµ Р°РєС‚СѓР°Р»СЊРЅР°СЏ РѕР±Р»РѕР¶РєР°',
      );
    });
  });
}
