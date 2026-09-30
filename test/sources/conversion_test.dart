// Юнит-тест слоя конверсии lib/sources/conversion.dart (Фаза 2, 2.2–2.3).
//
// Проверяет mediaItemToTrack — конверсию MediaItem (audio_service) в Track,
// которая была вынесена из lib/ui/widgets/queue_sheet.dart, чтобы UI не
// содержал конверсии моделей данных. Детерминированный тест: без сети,
// без реального HTTP — только чистые данные.
//
// Плюс Этап 2 серии 02: roundtrip качества через MediaItem.extras
// (PlayerConversions.toMediaItem → trackFromExtras) — QUALITY-01.
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/player_conversions.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/conversion.dart';
import 'package:player/core/youtube_cache.dart';

void main() {
  group('mediaItemToTrack', () {
    test('maps basic fields', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'muzmo_1',
        title: 'эвтаназия',
        artist: 'Psychosis, Pavshiy',
        duration: Duration(seconds: 240),
        extras: {'sourceId': 'muzmo'},
      ));
      expect(t.id, 'muzmo_1');
      expect(t.sourceId, 'muzmo');
      expect(t.title, 'эвтаназия');
      expect(t.artist, 'Psychosis, Pavshiy');
      expect(t.duration, Duration(seconds: 240));
    });

    test('falls back artist to empty string', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        extras: {'sourceId': 'youtube'},
      ));
      expect(t.artist, '');
    });

    test('prefers sourceId over source_id', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {'sourceId': 'soundcloud', 'source_id': 'youtube'},
      ));
      expect(t.sourceId, 'soundcloud');
    });

    test('falls back to source_id when sourceId missing', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {'source_id': 'muzmo'},
      ));
      expect(t.sourceId, 'muzmo');
    });

    test('defaults sourceId to local', () {
      final t = mediaItemToTrack(MediaItem(id: 'x', title: 'T'));
      expect(t.sourceId, 'local');
    });

    test('keeps quality fields and extra', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {
          'sourceId': 'youtube',
          'quality_score': 85,
          'quality_label': 'HD',
          'k': 'v',
        },
      ));
      expect(t.qualityScore, 85);
      expect(t.qualityLabel, 'HD');
      expect(t.extra['k'], 'v');
    });

    test('artworkUri maps to artworkUrl', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        artUri: Uri.parse('https://img.example.com/cover.jpg'),
        extras: {'sourceId': 'youtube'},
      ));
      expect(t.artworkUrl, contains('img.example.com'));
    });

    // Регрессионный тест рассинхронизации состояния кэша.
    // id у MediaItem — полный globalId (`sourceId:trackId`), а чистый id
    // живёт в extras['trackId'] (см. PlayerConversions.toMediaItem).
    // mediaItemToTrack должен брать чистый id из extras, иначе cacheId,
    // построенный для трека из очереди, не совпадёт с тем, что строит
    // большое меню плеера — и трек «в очереди» никогда не выглядит
    // закэшированным, хотя в большом плеере он «Cached».
    test('prefers clean trackId from extras over global id', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'muzmo:ABC123',
        title: 'T',
        artist: 'A',
        extras: {'sourceId': 'muzmo', 'trackId': 'ABC123'},
      ));
      expect(t.id, 'ABC123');
      expect(t.globalId, 'muzmo:ABC123');
    });

    test('falls back to item.id when trackId missing', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'muzmo:ABC123',
        title: 'T',
        artist: 'A',
        extras: {'sourceId': 'muzmo'},
      ));
      expect(t.id, 'muzmo:ABC123');
    });

    test('cacheId from queue matches cacheId from big player for same track',
        () {
      // Большой плеер (player_bottom_actions) строит Track с чистым id.
      const bigPlayerTrack = Track(
        id: 'ABC123',
        sourceId: 'muzmo',
        title: 'T',
        artist: 'A',
      );
      // Очередь строит Track через mediaItemToTrack(MediaItem из очереди).
      final queueTrack = mediaItemToTrack(MediaItem(
        id: 'muzmo:ABC123',
        title: 'T',
        artist: 'A',
        extras: {'sourceId': 'muzmo', 'trackId': 'ABC123'},
      ));

      final bigPlayerCacheId = YoutubeCache.cacheIdFor(
        sourceId: bigPlayerTrack.sourceId,
        trackId: bigPlayerTrack.id,
      );
      final queueCacheId = YoutubeCache.cacheIdFor(
        sourceId: queueTrack.sourceId,
        trackId: queueTrack.id,
      );

      expect(queueTrack.globalId, bigPlayerTrack.globalId);
      expect(queueCacheId, bigPlayerCacheId);
    });
  });

  group('QUALITY-01: toMediaItem → trackFromExtras roundtrip', () {
    setUp(() {
      // Отключаем lazy-read БД кастомных обложек (нет path_provider
      // в чистых unit-тестах).
      ArtworkHelper.disableDbReadsForTesting = true;
    });
    tearDown(() {
      ArtworkHelper.disableDbReadsForTesting = false;
    });

    test('soulseek quality survives Track → MediaItem → Track', () {
      const original = Track(
        id: 'res_1_2',
        sourceId: 'soulseek',
        title: 'Title',
        artist: 'Artist',
        duration: Duration(seconds: 240),
        qualityScore: 1411,
        qualityLabel: 'FLAC 24/96',
        extra: {
          'cacheKey': 'ck123',
          'bitrate': 1411,
          'sampleRate': 96000,
          'bitDepth': 24,
          'extension': 'flac',
          'peerUsername': 'peer',
          'remoteFilename': 'Music/Title.flac',
          'sizeBytes': 51000000,
        },
      );

      final item = PlayerConversions.toMediaItem(original);
      final restored = PlayerConversions.trackFromExtras(item);

      expect(restored.id, 'res_1_2');
      expect(restored.sourceId, 'soulseek');
      expect(restored.title, 'Title');
      expect(restored.artist, 'Artist');
      expect(restored.duration, const Duration(seconds: 240));
      expect(restored.qualityScore, 1411);
      expect(restored.qualityLabel, 'FLAC 24/96');
      expect(restored.extra['cacheKey'], 'ck123');
      expect(restored.extra['bitrate'], 1411);
      expect(restored.extra['sampleRate'], 96000);
      expect(restored.extra['bitDepth'], 24);
      expect(restored.extra['extension'], 'flac');
    });

    test('toMediaItem extras содержат качество (quality_score/label)', () {
      const track = Track(
        id: 'x',
        sourceId: 'youtube',
        title: 'T',
        artist: 'A',
        qualityScore: 95,
        qualityLabel: 'HD',
      );
      final extras = PlayerConversions.toMediaItem(track).extras!;
      expect(extras['quality_score'], 95);
      expect(extras['qualityLabel'], 'HD');
      expect(extras['quality_label'], 'HD');
    });

    test('track without quality → extras без null-мусора, restored null', () {
      const track = Track(
        id: 'plain',
        sourceId: 'youtube',
        title: 'T',
        artist: 'A',
      );
      final item = PlayerConversions.toMediaItem(track);
      expect(item.extras!.containsKey('quality_score'), isFalse);

      final restored = PlayerConversions.trackFromExtras(item);
      expect(restored.qualityScore, isNull);
      expect(restored.qualityLabel, isNull);
      // extra = сам extras map (с sourceId/trackId) — безопасно для
      // источников, не читающих эти ключи.
      expect(restored.extra['sourceId'], 'youtube');
    });

    test('trackFromExtras на MediaItem без extras не падает', () {
      const item = MediaItem(id: 'x', title: 'T');
      final restored = PlayerConversions.trackFromExtras(item);
      expect(restored.id, 'x');
      expect(restored.sourceId, '');
      expect(restored.extra, isEmpty);
    });

    test('trackFromExtras prefers clean trackId over globalId', () {
      final item = PlayerConversions.toMediaItem(const Track(
        id: 'ABC',
        sourceId: 'muzmo',
        title: 'T',
        artist: 'A',
      ));
      final restored = PlayerConversions.trackFromExtras(item);
      expect(restored.id, 'ABC');
      expect(restored.globalId, 'muzmo:ABC');
    });
  });
}
