import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/history_repository.dart';
import 'package:player/core/playlist_repository.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';

import '../setup/test_harness.dart';

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
    await HistoryRepository.instance.resetForTesting();
    await PlaylistRepository.instance.ensureLoaded();
    await HistoryRepository.instance.ensureLoaded();
    // Изолируем тесты: in-memory кэш URL обложек между тестами не переносим.
    ArtworkProvider.instance.clearMemCache();
  });

  tearDown(() async {
    await TestHarness.tearDownDb();
  });

  group('HistoryRepository artwork enrichment', () {
    test(
      'дозаполняет обложку трека без неё при reload (сначала из источника)',
      () async {
        SourceRegistry.instance.register(_ArtworkRestoreFakeSource());

        await HistoryRepository.instance.add(
          const Track(
            id: 'sc1',
            sourceId: 'soundcloud',
            title: 'Song',
            artist: 'Artist',
          ),
        );

        // reload() запускает фоновое обогащение обложек.
        await HistoryRepository.instance.reload();
        await HistoryRepository.instance.flushEnrichmentForTesting();

        expect(
          HistoryRepository.instance.current.first.track.artworkUrl,
          'https://i1.sndcdn.com/artworks-restored-t500x500.jpg',
          reason:
              'родная обложка источника восстанавливается по ID трека, '
              'как в плейлистах',
        );
      },
    );

    test(
      'обновляет протухший по TTL провайдерский URL при reload',
      () async {
        await HistoryRepository.instance.add(
          const Track(
            id: 'g1',
            sourceId: 'muzmo',
            title: 'Song',
            artist: 'Artist',
            artworkUrl: 'https://images.genius.com/old_600x600.png',
          ),
        );

        // В SQLite-кэше лежит ТОТ ЖЕ URL, но с просроченным TTL.
        final old = DateTime.now().subtract(
          ArtworkProvider.foundUrlTtl + const Duration(days: 1),
        );
        await ArtworkProvider.instance.cacheArtworkToDbForTesting(
          'Artist',
          'Song',
          'https://images.genius.com/old_600x600.png',
          old,
        );

        // Genius теперь вернёт НОВУЮ обложку.
        ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async =>
            'https://images.genius.com/new_600x600.png';
        ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
            null;

        await HistoryRepository.instance.reload();
        await HistoryRepository.instance.flushEnrichmentForTesting();

        expect(
          HistoryRepository.instance.current.first.track.artworkUrl,
          'https://images.genius.com/new_600x600.png',
          reason:
              'после истечения TTL обложка Genius перезапрошена и обновлена '
              'в истории автоматически',
        );
      },
    );

    test(
      'НЕ дёргает сеть для свежих совпадающих провайдерских URL',
      () async {
        await HistoryRepository.instance.add(
          const Track(
            id: 'g2',
            sourceId: 'muzmo',
            title: 'FreshSong',
            artist: 'FreshArtist',
            artworkUrl: 'https://images.genius.com/fresh_600x600.png',
          ),
        );

        // Свежая запись в SQLite-кэше — TTL не истёк.
        await ArtworkProvider.instance.cacheArtworkToDbForTesting(
          'FreshArtist',
          'FreshSong',
          'https://images.genius.com/fresh_600x600.png',
          DateTime.now(),
        );

        // Сеть не должна вызываться.
        ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for fresh URL');
        };
        ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for fresh URL');
        };

        await HistoryRepository.instance.reload();
        await HistoryRepository.instance.flushEnrichmentForTesting();

        expect(
          HistoryRepository.instance.current.first.track.artworkUrl,
          'https://images.genius.com/fresh_600x600.png',
          reason: 'свежий совпадающий провайдерский URL не перезапрашивается',
        );
      },
    );

    test(
      'синхронизирует рассинхронизированный URL с кэшем провайдера без сети',
      () async {
        await HistoryRepository.instance.add(
          const Track(
            id: 'g3',
            sourceId: 'muzmo',
            title: 'Desync',
            artist: 'DesyncArtist',
            artworkUrl: 'https://images.genius.com/old.jpg',
          ),
        );

        // Кэш провайдера СВЕЖИЙ, но хранит ДРУГОЙ URL — история «застряла»
        // на старом. Обновление должно произойти без сети.
        await ArtworkProvider.instance.cacheArtworkToDbForTesting(
          'DesyncArtist',
          'Desync',
          'https://images.genius.com/new.jpg',
          DateTime.now(),
        );

        ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for desync case');
        };
        ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
          throw StateError('network must not be called for desync case');
        };

        await HistoryRepository.instance.reload();
        await HistoryRepository.instance.flushEnrichmentForTesting();

        expect(
          HistoryRepository.instance.current.first.track.artworkUrl,
          'https://images.genius.com/new.jpg',
          reason:
              'рассинхронизированный URL обновлён до свежего значения '
              'из кэша провайдера без запроса сети',
        );
      },
    );

    test('URL, найденный историей, пропагируется в плейлисты', () async {
      // Тот же трек (по globalId) есть и в плейлисте, и в истории.
      const shared = Track(
        id: 'p1',
        sourceId: 'muzmo',
        title: 'Cross',
        artist: 'CrossArtist',
      );
      final p = PlaylistRepository.instance.create('Test');
      PlaylistRepository.instance.addTrack(p.id, shared);
      await PlaylistRepository.instance.flush();
      await HistoryRepository.instance.add(shared);

      ArtworkProvider.instance.cacheArtworkForTesting(
        'CrossArtist',
        'Cross',
        'https://images.genius.com/cross.jpg',
      );

      await HistoryRepository.instance.reload();
      await HistoryRepository.instance.flushEnrichmentForTesting();

      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        'https://images.genius.com/cross.jpg',
        reason: 'история получила обложку через обогащение',
      );
      expect(
        PlaylistRepository.instance.current.first.tracks.first.artworkUrl,
        'https://images.genius.com/cross.jpg',
        reason:
            'обложка, найденная историей, применилась и к плейлисту — '
            'в приложении везде одна и та же актуальная обложка',
      );
    });

    test('resetAllTrackArtworks очищает провайдерские URL и перезаполняет',
        () async {
      await HistoryRepository.instance.add(
        const Track(
          id: 'r1',
          sourceId: 'muzmo',
          title: 'Song Reset',
          artist: 'Artist',
          artworkUrl: 'https://images.genius.com/old.jpg',
        ),
      );

      // Сид in-memory кэша ДО сброса — findArtwork вернёт URL мгновенно.
      ArtworkProvider.instance.cacheArtworkForTesting(
        'Artist',
        'Song Reset',
        'https://images.genius.com/new.jpg',
      );

      HistoryRepository.instance.resetAllTrackArtworks();
      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        isNull,
        reason: 'провайдерский URL обнулён сразу после сброса',
      );

      await HistoryRepository.instance.flushEnrichmentForTesting();

      expect(
        HistoryRepository.instance.current.first.track.artworkUrl,
        'https://images.genius.com/new.jpg',
        reason:
            'обложка перезапрошена после сброса без ручного воспроизведения',
      );
    });
  });
}
