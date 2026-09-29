// test/core/cache_evictor_test.dart
//
// Тесты source-aware инвалидации кэша (план CACHE-01, раздел 5.6):
//  - Soulseek: evict нативного кэша по cacheKey + сброс Dart-индекса;
//  - YouTube-подобные: прежнее поведение YoutubeCache.evict по cacheId;
//  - ошибки нативного удаления не блокируют retry.

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/cache_evictor.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/soulseek_source.dart';

void main() {
  Track soulseekTrack({String? cacheKey}) => Track(
        id: 'result-1',
        sourceId: SoulseekSource.sourceId,
        title: 'Track',
        artist: 'Artist',
        extra: {
          'peerUsername': 'peer',
          'remoteFilename': '@@abc\\Track.flac',
          'sizeBytes': 1000,
          'cacheKey': ?cacheKey,
        },
      );

  group('evictTrackCache', () {
    test('soulseek track evicts native cache by cacheKey and resets index',
        () async {
      final removedKeys = <String>[];
      final forgottenKeys = <String>[];
      final evictedYoutubeIds = <String>[];

      await evictTrackCache(
        soulseekTrack(cacheKey: 'ck_abc'),
        removeSoulseekCache: removedKeys.add,
        forgetSoulseekCacheKey: forgottenKeys.add,
        evictYoutubeCache: (id) async => evictedYoutubeIds.add(id),
      );

      expect(removedKeys, ['ck_abc']);
      expect(forgottenKeys, ['ck_abc']);
      expect(evictedYoutubeIds, isEmpty);
    });

    test('soulseek track without cacheKey is a no-op', () async {
      var nativeCalled = false;
      var indexCalled = false;

      await evictTrackCache(
        soulseekTrack(cacheKey: null),
        removeSoulseekCache: (_) async => nativeCalled = true,
        forgetSoulseekCacheKey: (_) => indexCalled = true,
        evictYoutubeCache: (_) async => fail('must not touch YouTube cache'),
      );

      expect(nativeCalled, isFalse);
      expect(indexCalled, isFalse);
    });

    test('native removeCache failure does not block index reset', () async {
      final forgottenKeys = <String>[];

      await evictTrackCache(
        soulseekTrack(cacheKey: 'ck_abc'),
        removeSoulseekCache: (_) async => throw UnsupportedError('not android'),
        forgetSoulseekCacheKey: forgottenKeys.add,
        evictYoutubeCache: (_) async => fail('must not touch YouTube cache'),
      );

      expect(forgottenKeys, ['ck_abc']);
    });

    test('non-soulseek track evicts YoutubeCache by cacheId', () async {
      final evictedYoutubeIds = <String>[];
      final track = Track(
        id: 'sound123',
        sourceId: 'soundcloud',
        title: 'Track',
        artist: 'Artist',
      );

      await evictTrackCache(
        track,
        removeSoulseekCache: (_) async => fail('must not touch Soulseek cache'),
        forgetSoulseekCacheKey: (_) => fail('must not touch Soulseek index'),
        evictYoutubeCache: (id) async => evictedYoutubeIds.add(id),
      );

      expect(evictedYoutubeIds, ['soundcloud_sound123']);
    });
  });
}
