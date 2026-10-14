// Юнит-тесты общего ядра очереди (мобилка и десктоп) на фейковом бэкенде.

import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:player/core/playback/queue_engine.dart';
import 'package:player/core/playback/queue_environment.dart';
import 'package:player/core/player_service_interface.dart';
import 'package:player/sources/playback_source.dart';

import 'fakes.dart';

/// Даёт отработать цепочкам future/microtask внутри ядра.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeBackend backend;
  late FakeEnvironment env;
  late QueueEngine engine;

  Future<QueueEngine> create({bool persistVolume = false}) async {
    final e = QueueEngine(
      backend: backend,
      environment: env,
      persistVolume: persistVolume,
    );
    await e.ready;
    return e;
  }

  setUp(() async {
    backend = FakeBackend();
    env = FakeEnvironment();
    engine = await create();
  });

  tearDown(() => engine.dispose());

  final a = track('a'), b = track('b'), c = track('c');

  group('playback', () {
    test('setQueue resolves, loads and plays the start track', () async {
      await engine.setQueue([a, b, c], startIndex: 1);

      expect(engine.currentIndex, 1);
      expect(env.resolved, ['b']);
      expect(backend.loaded.single, isA<LocalFile>());
      expect(backend.calls, ['stop', 'load:fake:b', 'play']);
      expect(engine.mediaItemValue?.title, 'Title b');
      expect(engine.isLoading, isFalse);
    });

    test('startIndex out of range is clamped', () async {
      await engine.setQueue([a, b], startIndex: 7);
      expect(engine.currentIndex, 1);
    });

    test('a newer load cancels a slower one after resolve', () async {
      env.gates['a'] = Completer<void>();
      await engine.setQueue([a, b], startIndex: 0).timeout(
            const Duration(milliseconds: 20),
            onTimeout: () {},
          );
      await engine.playIndex(1);
      env.gates['a']!.complete();
      await settle();

      expect(backend.calls.where((c) => c.startsWith('load')),
          ['load:fake:b']);
      expect(engine.currentIndex, 1);
    });

    test('error → evict cache and retry once', () async {
      backend.loadError = StateError('bad cache');
      await engine.setQueue([a, b]);
      await settle();

      expect(env.evicted, ['a']);
      expect(backend.loaded, hasLength(1));
      expect(engine.currentIndex, 0);
    });

    test('error after retry skips to the next track', () async {
      env.failingIds.add('a');
      await engine.setQueue([a, b]);
      await settle();

      expect(env.evicted, ['a']);
      expect(engine.currentIndex, 1);
      expect(backend.calls.last, 'play');
    });

    test('non-retryable error skips to the next track without a retry',
        () async {
      env.failingIds.add('a');
      env.retryable = (_) => false;
      await engine.setQueue([a, b]);
      await settle();

      expect(env.resolved.where((id) => id == 'a'), hasLength(1));
      expect(env.evicted, isEmpty);
      expect(engine.currentIndex, 1);
    });

    test('failing last track goes back to the previous one', () async {
      env.failingIds.add('b');
      await engine.setQueue([a, b], startIndex: 1);
      await settle();
      expect(engine.currentIndex, 0);
    });

    test('play() on an idle backend loads the current track', () async {
      env.session = (queue: [a, b], currentIndex: 1, positionMs: 0);
      engine = await create();

      await engine.play();
      expect(backend.calls, ['stop', 'load:fake:b', 'play']);
    });

    test('skipToPrevious after 3 s restarts the track', () async {
      await engine.setQueue([a, b], startIndex: 1);
      backend.position = const Duration(seconds: 10);
      await engine.skipToPrevious();
      expect(backend.calls.last, 'seek:0');
      expect(engine.currentIndex, 1);

      backend.position = const Duration(seconds: 1);
      await engine.skipToPrevious();
      expect(engine.currentIndex, 0);
    });
  });

  group('track end', () {
    test('LoopMode.off advances and stops at the end of the queue', () async {
      await engine.setQueue([a, b]);
      backend.finishTrack();
      await settle();
      expect(engine.currentIndex, 1);

      final loads = backend.loaded.length;
      backend.finishTrack();
      await settle();
      expect(backend.loaded.length, loads);
      expect(engine.currentIndex, 1);
    });

    test('LoopMode.all wraps to the first track', () async {
      await engine.setLoopMode(LoopMode.all);
      await engine.setQueue([a, b], startIndex: 1);
      backend.finishTrack();
      await settle();
      expect(engine.currentIndex, 0);
    });

    test('LoopMode.one replays the same track', () async {
      await engine.cycleLoopMode();
      await engine.cycleLoopMode();
      expect(engine.loopMode, LoopMode.one);
      await engine.setQueue([a, b]);
      backend.finishTrack();
      await settle();
      expect(engine.currentIndex, 0);
      expect(backend.loaded, hasLength(2));
    });

    test('completion while loading is ignored', () async {
      env.gates['a'] = Completer<void>();
      unawaited(engine.setQueue([a, b]));
      await settle();
      backend.finishTrack();
      await settle();
      expect(engine.currentIndex, 0);
      env.gates['a']!.complete();
    });

    test('sleep timer "end of track" stops instead of advancing', () async {
      await engine.setQueue([a, b]);
      await engine.setStopAtEndOfSong();
      backend.finishTrack();
      await settle();

      expect(engine.currentIndex, 0);
      expect(engine.sleepTimerMode, SleepTimerMode.off);
    });

    test('timed sleep timer switches to end-of-track when it fires',
        () async {
      engine.startSleepTimer(const Duration(milliseconds: 10));
      expect(engine.sleepTimerMode, SleepTimerMode.time);
      expect(engine.sleepTimerEndTime, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.sleepTimerMode, SleepTimerMode.endOfTrack);
      expect(engine.sleepTimerEndTime, isNull);
    });
  });

  group('queue edits', () {
    test('insertToQueue puts the track right after the current one',
        () async {
      await engine.setQueue([a, b], startIndex: 0);
      await engine.insertToQueue(c);
      expect(engine.trackQueue.map((t) => t.id), ['a', 'c', 'b']);
      expect(engine.currentIndex, 0);
    });

    test('insertToQueue with nothing playing inserts at the start', () async {
      await engine.addToQueue(a);
      await engine.insertToQueue(b);
      expect(engine.trackQueue.map((t) => t.id), ['b', 'a']);
    });

    test('remove before the current track shifts the index', () async {
      await engine.setQueue([a, b, c], startIndex: 2);
      await engine.removeFromQueue(0);
      expect(engine.currentIndex, 1);
      expect(engine.trackQueue.map((t) => t.id), ['b', 'c']);
    });

    test('removing the current track stops playback', () async {
      await engine.setQueue([a, b], startIndex: 1);
      await engine.removeFromQueue(1);
      expect(engine.currentIndex, -1);
      expect(backend.calls.last, 'stop');
    });

    test('reorder keeps the current track tracked', () async {
      await engine.setQueue([a, b, c], startIndex: 1);
      await engine.reorderQueueItem(1, 2);
      expect(engine.currentIndex, 2);
      await engine.reorderQueueItem(0, 2);
      expect(engine.currentIndex, 1);
      await engine.reorderQueueItem(2, 0);
      expect(engine.currentIndex, 2);
      expect(engine.trackQueue.map((t) => t.id), ['a', 'c', 'b']);
    });

    test('shuffle moves the current track to the front', () async {
      await engine.setQueue([a, b, c], startIndex: 2);
      await engine.shuffleQueue(random: Random(1));
      expect(engine.currentIndex, 0);
      expect(engine.trackQueue.first.id, 'c');
      expect(engine.trackQueue.map((t) => t.id).toSet(), {'a', 'b', 'c'});
    });

    test('every mutation publishes a queue snapshot', () async {
      final snapshots = <List<String>>[];
      final sub = engine.trackQueueStream
          .listen((q) => snapshots.add(q.map((t) => t.id).toList()));
      await engine.addToQueue(a);
      await engine.addToQueue(b);
      await engine.removeFromQueue(0);
      await settle();
      await sub.cancel();
      expect(snapshots, [
        <String>[],
        ['a'],
        ['a', 'b'],
        ['b'],
      ]);
    });

    test('clearQueue stops and saves an empty session', () async {
      await engine.setQueue([a, b]);
      await engine.clearQueue();

      expect(engine.trackQueue, isEmpty);
      expect(engine.currentIndex, -1);
      expect(engine.mediaItemValue, isNull);
      expect(env.saved.last.queue, isEmpty);
    });
  });

  group('history', () {
    test('track is recorded after playing past the threshold', () async {
      await engine.setQueue([a]);
      backend.emitPosition(const Duration(milliseconds: 500));
      expect(env.history, isEmpty);

      backend.emitPosition(const Duration(seconds: 2));
      backend.emitPosition(const Duration(seconds: 3));
      await settle();
      expect(env.history.map((t) => t.id), ['a']);
    });

    test('paused playback is not recorded', () async {
      await engine.setQueue([a]);
      backend.playing = false;
      backend.emitPosition(const Duration(seconds: 2));
      expect(env.history, isEmpty);
    });
  });

  group('session', () {
    test('restore shows the saved track without loading audio', () async {
      env.session = (queue: [a, b], currentIndex: 1, positionMs: 0);
      engine = await create();

      expect(engine.trackQueue.map((t) => t.id), ['a', 'b']);
      expect(engine.currentIndex, 1);
      expect(engine.mediaItemValue?.title, 'Title b');
      final state = await engine.playbackState.first;
      expect(state.processingState, AudioProcessingState.ready);
      expect(state.playing, isFalse);
      expect(backend.loaded, isEmpty);
    });

    test('restore does not replace a queue built meanwhile', () async {
      final gate = Completer<void>();
      final slowEnv = _SlowSessionEnvironment(gate)
        ..session = (queue: [a], currentIndex: 0, positionMs: 0);
      final e = QueueEngine(backend: FakeBackend(), environment: slowEnv);
      await e.addToQueue(c);
      gate.complete();
      await e.ready;
      expect(e.trackQueue.map((t) => t.id), ['c']);
      await e.dispose();
    });

    test('pause saves the session with the current position', () async {
      await engine.setQueue([a, b], startIndex: 1);
      backend.position = const Duration(seconds: 42);
      await engine.pause();

      final saved = env.saved.last;
      expect(saved.currentIndex, 1);
      expect(saved.positionMs, 42000);
      expect(saved.queue.map((t) => t.id), ['a', 'b']);
    });

    test('mutations are saved once after the debounce', () async {
      await engine.addToQueue(a);
      await engine.addToQueue(b);
      await engine.addToQueue(c);
      expect(env.saved, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(env.saved, hasLength(1));
      expect(env.saved.single.queue, hasLength(3));
    });

    test('idle restored session is not overwritten by a forced save',
        () async {
      env.session = (queue: [a], currentIndex: 0, positionMs: 0);
      engine = await create();
      await engine.saveSession();
      expect(env.saved, isEmpty);
    });
  });

  group('boost and volume', () {
    test('saved boost is restored and applied to the backend', () async {
      env.settings['boost_db_v1'] = '20';
      engine = await create();
      expect(engine.boostDb, 12.0);
      expect(backend.boost, 12.0);
    });

    test('setBoost applies and persists', () async {
      engine.setBoost(4);
      await settle();
      expect(backend.boost, 4);
      expect(env.settings['boost_db_v1'], '4.0');
    });

    test('volume is persisted only when asked', () async {
      await engine.setVolume(0.5);
      expect(backend.volume, 0.5);
      expect(env.settings.containsKey('volume_v1'), isFalse);

      env.settings['volume_v1'] = '0.3';
      engine = await create(persistVolume: true);
      expect(engine.volume, 0.3);
      await engine.setVolume(0.7);
      expect(env.settings['volume_v1'], '0.7');
    });
  });

  group('artwork', () {
    test('fetched artwork updates the queue, media item and repos', () async {
      env.artwork['a'] = 'https://img/a.jpg';
      await engine.setQueue([a, b]);
      await settle();

      expect(engine.trackQueue.first.artworkUrl, 'https://img/a.jpg');
      expect(engine.mediaItemValue?.artUri.toString(), 'https://img/a.jpg');
      expect(env.persistedArtwork['fake:a'], 'https://img/a.jpg');
    });

    test('artwork of the next track does not touch the media item',
        () async {
      env.artwork['b'] = 'https://img/b.jpg';
      await engine.setQueue([a, b]);
      await settle();

      expect(engine.trackQueue[1].artworkUrl, 'https://img/b.jpg');
      expect(engine.mediaItemValue?.title, 'Title a');
      expect(engine.mediaItemValue?.artUri, isNull);
    });

    test('custom artwork replaces and resets the current media item',
        () async {
      await engine.setQueue([a.copyWith(artworkUrl: 'https://orig/a.jpg')]);
      await engine.updateCustomArtwork('a', '/covers/a.png');
      expect(engine.trackQueue.first.artworkUrl, '/covers/a.png');
      expect(engine.mediaItemValue?.artUri, Uri.file('/covers/a.png'));
      expect(env.persistedArtwork['fake:a'], '/covers/a.png');

      await engine.resetCustomArtwork('a');
      expect(engine.trackQueue.first.artworkUrl, 'https://orig/a.jpg');
      expect(engine.mediaItemValue?.artUri.toString(), 'https://orig/a.jpg');
    });
  });
}

class _SlowSessionEnvironment extends FakeEnvironment {
  _SlowSessionEnvironment(this.gate);
  final Completer<void> gate;

  @override
  Future<SavedSession?> loadSession() async {
    await gate.future;
    return session;
  }
}
