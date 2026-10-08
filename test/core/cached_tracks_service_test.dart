// CachedTracksService: сводит стриминговый кэш (YoutubeCache + индекс
// audio_cache_index) и Soulseek-кэш (DI-колбэки вместо MethodChannel)
// в один список и раздаёт действия по хранилищам.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:player/core/cached_tracks_service.dart';
import 'package:player/core/database/app_database.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/soulseek_models.dart';

import '../setup/test_harness.dart';

Track _muzmo(String id, {String title = 'Song'}) =>
    Track(id: id, sourceId: 'muzmo', title: title, artist: 'Artist');

SoulseekCacheEntry _slsk(
  String key, {
  DateTime? cachedAt,
  bool complete = true,
  bool pinned = false,
  int size = 3000,
}) =>
    SoulseekCacheEntry(
      cacheKey: key,
      localPath: '/data/cache/$key.flac',
      sizeBytes: size,
      complete: complete,
      pinned: pinned,
      title: 'Soul $key',
      artist: 'Peer',
      cachedAt: cachedAt,
    );

Track _soulseekTrack(SoulseekCacheEntry e) => Track(
      id: e.cacheKey,
      sourceId: 'soulseek',
      title: e.title ?? '',
      artist: e.artist ?? '',
      extra: {'cacheKey': e.cacheKey},
    );

void main() {
  TestHarness.ensureInitialized();

  late Directory audioDir;
  late List<SoulseekCacheEntry> soulseekEntries;
  late List<String> removedSoulseek;
  late bool soulseekRemoveResult;
  late Map<String, bool> pinnedSoulseek;
  late List<Track> knownTracks;

  setUp(() async {
    await TestHarness.setUpDb();
    audioDir = Directory.systemTemp.createTempSync('cached_tracks_');
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(audioDir);
    soulseekEntries = [];
    removedSoulseek = [];
    soulseekRemoveResult = true;
    pinnedSoulseek = {};
    knownTracks = [];
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setProtectedId(null);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    await TestHarness.tearDownDb();
    try {
      audioDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  CachedTracksService service({
    Future<List<SoulseekCacheEntry>> Function()? loadSoulseek,
  }) {
    return CachedTracksService(
      loadSoulseekEntries: loadSoulseek ?? () async => soulseekEntries,
      removeSoulseekEntry: (key) async {
        removedSoulseek.add(key);
        return soulseekRemoveResult;
      },
      pinSoulseekEntry: (key, pinned) async => pinnedSoulseek[key] = pinned,
      soulseekTrackFor: _soulseekTrack,
      knownTracks: () => knownTracks,
    );
  }

  File writeAudio(String cacheId, {int size = 1000, DateTime? modified}) {
    final f = File(p.join(audioDir.path, '$cacheId.mp3'))
      ..writeAsStringSync('x' * size);
    if (modified != null) f.setLastModifiedSync(modified);
    return f;
  }

  group('loadAll', () {
    test('сводит оба хранилища, новые сверху, без даты — в конце', () async {
      writeAudio('muzmo_1', size: 1000);
      await AppDatabase.instance.upsertAudioCacheEntry(
        'muzmo_1',
        _muzmo('1', title: 'Indexed'),
        cachedAt: DateTime(2026, 10, 5),
      );
      soulseekEntries = [
        _slsk('new', cachedAt: DateTime(2026, 10, 7)),
        _slsk('nodate'),
      ];

      final all = await service().loadAll();

      expect(all.map((t) => t.key), ['new', 'muzmo_1', 'nodate']);
      final streaming = all[1];
      expect(streaming.store, CacheStore.streaming);
      expect(streaming.track.title, 'Indexed');
      expect(streaming.sizeBytes, 1000);
      expect(streaming.cachedAt, DateTime(2026, 10, 5));
      expect(all.first.store, CacheStore.soulseek);
      expect(all.first.track.extra['cacheKey'], 'new');
    });

    test('незавершённые Soulseek-записи не показываются', () async {
      soulseekEntries = [_slsk('done'), _slsk('partial', complete: false)];

      final all = await service().loadAll();

      expect(all.map((t) => t.key), ['done']);
    });

    test('без индекса: метаданные из плейлистов/истории, индекс дописывается',
        () async {
      final mtime = DateTime(2026, 9, 30, 10);
      writeAudio('muzmo_42', modified: mtime);
      knownTracks = [_muzmo('42', title: 'From history')];

      final all = await service().loadAll();

      expect(all.single.track.title, 'From history');
      expect(all.single.cachedAt, mtime);
      // Дозапись индекса — fire-and-forget.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final index = await AppDatabase.instance.getAudioCacheIndex();
      expect(index['muzmo_42']?.track.title, 'From history');
      expect(index['muzmo_42']?.cachedAt, mtime);
    });

    test('неизвестный файл → трек-заглушка, играбельный по id', () async {
      writeAudio('soundcloud_abc');

      final track = (await service().loadAll()).single.track;

      expect(track.sourceId, 'soundcloud');
      expect(track.id, 'abc');
      expect(track.title, 'soundcloud_abc');
    });

    test('записи индекса без файла подчищаются, идущая загрузка — нет',
        () async {
      writeAudio('muzmo_1');
      File(p.join(audioDir.path, 'muzmo_3.mp3.part')).writeAsStringSync('p');
      for (final id in ['1', '2', '3']) {
        await AppDatabase.instance.upsertAudioCacheEntry('muzmo_$id', _muzmo(id));
      }

      await service().loadAll();
      // Подчистка — fire-and-forget.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect((await AppDatabase.instance.getAudioCacheIndex()).keys,
          unorderedEquals(['muzmo_1', 'muzmo_3']));
    });

    test('Soulseek недоступен (не Android) — только стриминговый кэш',
        () async {
      writeAudio('muzmo_1');

      final all = await service(
        loadSoulseek: () async => throw UnsupportedError('not android'),
      ).loadAll();

      expect(all.map((t) => t.key), ['muzmo_1']);
    });

    test('CacheUsage считает размеры по хранилищам', () {
      CachedTrack item(CacheStore store, int size) => CachedTrack(
            key: '$store$size',
            store: store,
            track: _muzmo('$size'),
            sizeBytes: size,
            cachedAt: null,
            pinned: false,
          );

      final usage = CacheUsage.of([
        item(CacheStore.streaming, 100),
        item(CacheStore.streaming, 50),
        item(CacheStore.soulseek, 1000),
      ]);

      expect(usage.streamingBytes, 150);
      expect(usage.soulseekBytes, 1000);
      expect(usage.totalBytes, 1150);
      expect(usage.trackCount, 3);
    });
  });

  group('actions', () {
    test('remove: файл стримингового кэша и запись индекса удаляются',
        () async {
      final f = writeAudio('muzmo_1');
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _muzmo('1'));
      final svc = service();
      final item = (await svc.loadAll()).single;

      await svc.remove(item);

      expect(f.existsSync(), isFalse);
      expect(await AppDatabase.instance.getAudioCacheIndex(), isEmpty);
      expect(removedSoulseek, isEmpty);
    });

    test('remove: играющий трек не удаляется, pin и индекс сохраняются',
        () async {
      final f = writeAudio('muzmo_1');
      await AppDatabase.instance.upsertAudioCacheEntry('muzmo_1', _muzmo('1'));
      await YoutubeCache.instance.pin('muzmo_1');
      // ignore: invalid_use_of_visible_for_testing_member
      YoutubeCache.instance.setProtectedId('muzmo_1');
      final svc = service();
      final item = (await svc.loadAll()).single;

      await expectLater(svc.remove(item), throwsA(isA<CacheActionException>()));

      expect(f.existsSync(), isTrue);
      expect(YoutubeCache.instance.isPinned('muzmo_1'), isTrue);
      expect(await AppDatabase.instance.getAudioCacheIndex(), contains('muzmo_1'));
      await YoutubeCache.instance.unpin('muzmo_1');
    });

    test('remove: отказ нативного кэша — ошибка, а не «удалено»', () async {
      soulseekEntries = [_slsk('ck1')];
      soulseekRemoveResult = false;
      final svc = service();

      await expectLater(
        svc.remove((await svc.loadAll()).single),
        throwsA(isA<CacheActionException>()),
      );
    });

    test('clearSoulseek: неудалённые файлы и недоступный сервис — ошибка',
        () async {
      soulseekEntries = [_slsk('a'), _slsk('b')];
      soulseekRemoveResult = false;
      await expectLater(
        service().clearSoulseek(),
        throwsA(isA<CacheActionException>()),
      );

      await expectLater(
        service(loadSoulseek: () async => throw StateError('NOT_CONNECTED'))
            .clearSoulseek(),
        throwsA(isA<CacheActionException>()),
      );
    });

    test('remove: Soulseek-трек уходит в нативный кэш', () async {
      soulseekEntries = [_slsk('ck1')];
      final svc = service();

      await svc.remove((await svc.loadAll()).single);

      expect(removedSoulseek, ['ck1']);
    });

    test('setPinned маршрутизируется по хранилищу', () async {
      writeAudio('muzmo_1');
      soulseekEntries = [_slsk('ck1', cachedAt: DateTime(2026))];
      final svc = service();
      final items = {for (final i in await svc.loadAll()) i.key: i};

      final streamingItem = await svc.setPinned(items['muzmo_1']!, true);
      final soulseekItem = await svc.setPinned(items['ck1']!, true);

      expect(streamingItem.pinned, isTrue);
      expect(YoutubeCache.instance.isPinned('muzmo_1'), isTrue);
      expect(soulseekItem.pinned, isTrue);
      expect(soulseekItem.key, 'ck1');
      expect(pinnedSoulseek, {'ck1': true});

      await svc.setPinned(streamingItem, false);
      expect(YoutubeCache.instance.isPinned('muzmo_1'), isFalse);
    });

    test('clearAudio чистит оба хранилища', () async {
      final f = writeAudio('muzmo_1');
      soulseekEntries = [_slsk('a'), _slsk('b')];

      await service().clearAudio();

      expect(f.existsSync(), isFalse);
      expect(removedSoulseek, ['a', 'b']);
    });
  });
}

