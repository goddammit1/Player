import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'package:player/core/playlist_cache_service.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';

import '../setup/test_harness.dart';

/// Unit tests for [PlaylistCacheService].
///
/// Fixture follows the youtube_cache_test.dart pattern: a real temp
/// directory via `setAudioDirForTesting` and a real (ffi) database via
/// [TestHarness] because `YoutubeCache.pin` persists the pinned set into
/// the settings table (`cache_pinned_ids`).
///
/// Fakes:
/// - [_FakeSource] — a [TrackSource] with a controllable
///   `resolveStreamUrl` (URL / error) and a call counter.
/// - [_FakeAdapter] — an [HttpClientAdapter] with a queue of scripted
///   responses (bytes / error / slow stream for cancellation). The real
///   Dio download pipeline is used, including writing to `savePath`.
void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  late SourceRegistry registry;
  late _FakeAdapter adapter;

  PlaylistCacheService buildService() => PlaylistCacheService(
        cache: YoutubeCache.instance,
        registry: registry,
        dioFactory: () => Dio()..httpClientAdapter = adapter,
      );

  Track track(String id, {String sourceId = _FakeSource.sourceId}) => Track(
        id: id,
        sourceId: sourceId,
        title: 'Track $id',
        artist: 'Artist $id',
      );

  String cacheIdOf(Track t) =>
      YoutubeCache.cacheIdFor(sourceId: t.sourceId, trackId: t.id);

  File fileOf(Track t) => File(p.join(tempDir.path, '${cacheIdOf(t)}.mp3'));

  setUp(() async {
    await TestHarness.setUpDb();
    tempDir = Directory.systemTemp.createTempSync('playlist_cache_test_');
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(tempDir);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();

    // Isolated registry state: the singleton is reset between tests.
    registry = SourceRegistry.instance;
    adapter = _FakeAdapter();
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    await SourceRegistry.instance.disposeAll();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
    await TestHarness.tearDownDb();
  });

  // ═════════════════════════════════════════════════════════════════
  //  Happy path
  // ═════════════════════════════════════════════════════════════════

  test('happy path: three tracks are downloaded sequentially and pinned',
      () async {
    final source = _FakeSource(url: 'https://fake/stream');
    registry.register(source);
    adapter
      ..enqueueBytes(List<int>.filled(100, 1))
      ..enqueueBytes(List<int>.filled(100, 2))
      ..enqueueBytes(List<int>.filled(100, 3));

    final tracks = [track('a'), track('b'), track('c')];
    final result = await buildService().cacheTracks(tracks);

    expect(result.downloaded, 3);
    expect(result.failed, 0);
    expect(result.skippedCached, 0);
    expect(result.cancelled, isFalse);
    expect(adapter.requestCount, 3);
    expect(source.resolveCalls, 3);
    for (final t in tracks) {
      expect(await fileOf(t).exists(), isTrue, reason: '${t.id} file');
      // ignore: invalid_use_of_visible_for_testing_member
      expect(YoutubeCache.instance.isPinned(cacheIdOf(t)), isTrue);
    }
    // Content of the second file proves sequential, ordered downloads.
    expect(await fileOf(tracks[1]).readAsBytes(), List<int>.filled(100, 2));
  });

  // ═════════════════════════════════════════════════════════════════
  //  Already cached
  // ═════════════════════════════════════════════════════════════════

  test('already cached track is re-pinned without touching the network',
      () async {
    final source = _FakeSource(url: 'https://fake/stream');
    registry.register(source);
    final t = track('cached');
    await fileOf(t).writeAsBytes(List<int>.filled(10, 7));
    // Not pinned beforehand: the service must re-pin it.
    // ignore: invalid_use_of_visible_for_testing_member
    expect(YoutubeCache.instance.isPinned(cacheIdOf(t)), isFalse);

    final result = await buildService().cacheTracks([t]);

    expect(result.skippedCached, 1);
    expect(result.downloaded, 0);
    expect(adapter.requestCount, 0);
    expect(source.resolveCalls, 0);
    // ignore: invalid_use_of_visible_for_testing_member
    expect(YoutubeCache.instance.isPinned(cacheIdOf(t)), isTrue);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Disabled source
  // ═════════════════════════════════════════════════════════════════

  test('track with disabled source is skipped, network untouched', () async {
    // registerDefaults marks 'youtube' as disabled.
    registry.registerDefaults();
    final t = track('yt1', sourceId: 'youtube');

    final progress = <PlaylistCacheProgress>[];
    final result = await buildService().cacheTracks(
      [t],
      onProgress: progress.add,
    );

    expect(result.skippedDisabled, 1);
    expect(result.total, 1);
    expect(result.downloaded, 0);
    expect(adapter.requestCount, 0);
    // The progress total excludes disabled tracks entirely.
    expect(progress.every((p) => p.total == 0), isTrue);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Per-track network failure
  // ═════════════════════════════════════════════════════════════════

  test('network failure on one track does not abort the batch', () async {
    registry.register(_FakeSource(url: 'https://fake/stream'));
    adapter
      ..enqueueBytes(List<int>.filled(50, 1))
      ..enqueueError(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionError,
          error: 'boom',
        ),
      )
      ..enqueueBytes(List<int>.filled(50, 3));

    final tracks = [track('a'), track('bad'), track('c')];
    final result = await buildService().cacheTracks(tracks);

    expect(result.downloaded, 2);
    expect(result.failed, 1);
    expect(await fileOf(tracks[0]).exists(), isTrue);
    expect(await fileOf(tracks[2]).exists(), isTrue);
    expect(await fileOf(tracks[1]).exists(), isFalse);
    // The partial file of the failed track is gone.
    final leftovers = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'))
        .toList();
    expect(leftovers, isEmpty);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Resolve failure
  // ═════════════════════════════════════════════════════════════════

  test('resolveStreamUrl error counts as failed, download not attempted',
      () async {
    registry.register(_FakeSource(error: StateError('resolve failed')));

    final result = await buildService().cacheTracks([track('x')]);

    expect(result.failed, 1);
    expect(result.downloaded, 0);
    expect(adapter.requestCount, 0);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Cancellation between tracks
  // ═════════════════════════════════════════════════════════════════

  test('cancellation between tracks stops the batch cleanly', () async {
    registry.register(_FakeSource(url: 'https://fake/stream'));
    adapter
      ..enqueueBytes(List<int>.filled(50, 1))
      ..enqueueBytes(List<int>.filled(50, 2));

    final cancelToken = CancelToken();
    final tracks = [track('a'), track('b')];
    final result = await buildService().cacheTracks(
      tracks,
      cancelToken: cancelToken,
      onProgress: (p) {
        // Cancel after the first track completes.
        if (p.completed == 1) cancelToken.cancel();
      },
    );

    expect(result.cancelled, isTrue);
    expect(result.downloaded, 1);
    expect(adapter.requestCount, 1);
    expect(await fileOf(tracks[0]).exists(), isTrue);
    expect(await fileOf(tracks[1]).exists(), isFalse);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Cancellation during a download
  // ═════════════════════════════════════════════════════════════════

  test('cancellation during download removes .part and skips pin', () async {
    registry.register(_FakeSource(url: 'https://fake/stream'));
    final cancelToken = CancelToken();
    // Slow stream: emits chunks with delays until cancelled.
    adapter.enqueueSlowBytes(
      List<int>.filled(1024, 9),
      chunkSize: 64,
      chunkDelay: const Duration(milliseconds: 20),
    );

    final t = track('slow');
    final future = buildService().cacheTracks(
      [t],
      cancelToken: cancelToken,
      onProgress: (p) {
        if (p.currentProgress != null && !cancelToken.isCancelled) {
          cancelToken.cancel();
        }
      },
    );

    final result = await future;

    expect(result.cancelled, isTrue);
    expect(result.downloaded, 0);
    expect(result.failed, 0);
    expect(await fileOf(t).exists(), isFalse);
    expect(
      tempDir.listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
    // ignore: invalid_use_of_visible_for_testing_member
    expect(YoutubeCache.instance.isPinned(cacheIdOf(t)), isFalse);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Edge cases: empty list / all disabled
  // ═════════════════════════════════════════════════════════════════

  test('empty track list returns zeroed result', () async {
    final progress = <PlaylistCacheProgress>[];
    final result = await buildService().cacheTracks([], onProgress: progress.add);

    expect(result.total, 0);
    expect(result.downloaded, 0);
    expect(result.cancelled, isFalse);
    expect(adapter.requestCount, 0);
  });

  test('all-disabled list returns only skippedDisabled', () async {
    registry.registerDefaults();
    final result = await buildService().cacheTracks([
      track('y1', sourceId: 'youtube'),
      track('y2', sourceId: 'youtube'),
    ]);

    expect(result.skippedDisabled, 2);
    expect(result.total, 2);
    expect(result.downloaded, 0);
    expect(adapter.requestCount, 0);
  });

  // ═════════════════════════════════════════════════════════════════
  //  Progress callbacks
  // ═════════════════════════════════════════════════════════════════

  test('progress callbacks are monotonic and well-formed', () async {
    registry.register(_FakeSource(url: 'https://fake/stream'));
    adapter
      ..enqueueBytes(List<int>.filled(100, 1), chunkSize: 25)
      ..enqueueBytes(List<int>.filled(100, 2), chunkSize: 25);

    final progress = <PlaylistCacheProgress>[];
    final tracks = [track('a'), track('b')];
    final result = await buildService().cacheTracks(
      tracks,
      onProgress: progress.add,
    );

    expect(result.downloaded, 2);
    expect(progress, isNotEmpty);

    var lastCompleted = -1;
    for (final p in progress) {
      expect(p.total, 2);
      expect(p.completed, greaterThanOrEqualTo(lastCompleted),
          reason: 'completed must be monotonic');
      lastCompleted = p.completed;
      expect(p.completed, lessThanOrEqualTo(2));
      if (p.currentProgress != null) {
        expect(p.currentProgress, inInclusiveRange(0.0, 1.0));
      }
      // While a track is in flight its title is one of the playlist titles.
      if (p.completed < 2) {
        expect(
          ['Track a', 'Track b'],
          contains(p.currentTitle),
        );
      }
    }
    // Titles of processed tracks appear in order.
    final titles = progress.map((p) => p.currentTitle).toSet();
    expect(titles, containsAll(['Track a', 'Track b']));
    // Final snapshot reflects full completion.
    expect(progress.last.completed, 2);
  });

  test('progress currentProgress is null when content length unknown',
      () async {
    registry.register(_FakeSource(url: 'https://fake/stream'));
    // No content-length header → total <= 0 → currentProgress == null.
    adapter.enqueueBytes(
      List<int>.filled(64, 5),
      chunkSize: 16,
      withContentLength: false,
    );

    final progress = <PlaylistCacheProgress>[];
    final result = await buildService()
        .cacheTracks([track('nolength')], onProgress: progress.add);

    expect(result.downloaded, 1);
    final inFlight =
        progress.where((p) => p.currentTitle == 'Track nolength').toList();
    expect(inFlight, isNotEmpty);
    // All in-flight snapshots before completion have null progress.
    expect(
      inFlight.where((p) => p.completed == 0).every((p) => p.currentProgress == null),
      isTrue,
    );
  });
}

// ═════════════════════════════════════════════════════════════════════
//  Fakes
// ═════════════════════════════════════════════════════════════════════

/// Controllable [TrackSource] fake. Registered under a muzmo-like id so
/// `cacheIdFor` prefixes ids deterministically.
class _FakeSource extends TrackSource {
  _FakeSource({String? url, Object? error})
      : _url = url,
        _error = error;

  static const String sourceId = 'fakesrc';

  final String? _url;
  final Object? _error;
  int resolveCalls = 0;

  @override
  String get id => sourceId;

  @override
  String get displayName => 'Fake Source';

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async => [];

  @override
  Future<String> resolveStreamUrl(Track track) async {
    resolveCalls++;
    final e = _error;
    if (e != null) throw e;
    return _url!;
  }

  @override
  Future<AudioSource> createAudioSource(Track track) =>
      throw UnimplementedError('not needed in tests');
}

/// Scripted [HttpClientAdapter]: each queued item corresponds to one
/// request, in order. Supports byte bodies (optionally chunked/slow),
/// immediate errors, and cancellation through [cancelFuture].
class _FakeAdapter implements HttpClientAdapter {
  final List<_ScriptedResponse> _queue = [];
  int requestCount = 0;

  void enqueueBytes(
    List<int> bytes, {
    int? chunkSize,
    bool withContentLength = true,
  }) {
    _queue.add(_ScriptedBytes(
      bytes,
      chunkSize: chunkSize,
      withContentLength: withContentLength,
    ));
  }

  void enqueueSlowBytes(
    List<int> bytes, {
    required int chunkSize,
    required Duration chunkDelay,
  }) {
    _queue.add(_ScriptedBytes(bytes, chunkSize: chunkSize, delay: chunkDelay));
  }

  void enqueueError(Object error) {
    _queue.add(_ScriptedError(error));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    if (_queue.isEmpty) {
      throw StateError('No scripted response for request #$requestCount');
    }
    final scripted = _queue.removeAt(0);
    if (scripted is _ScriptedError) {
      throw scripted.error;
    }
    final bytes = (scripted as _ScriptedBytes);
    return ResponseBody(
      _chunkedStream(bytes),
      200,
      headers: bytes.withContentLength
          ? {
              Headers.contentLengthHeader: [bytes.bytes.length.toString()],
            }
          : {},
    );
  }

  /// Emits bytes in chunks with an optional inter-chunk delay.
  /// No explicit cancellation handling is needed: on `CancelToken.cancel`
  /// Dio's internal `handleResponseStream` cancels the subscription (which
  /// pauses this generator) and fails the request with the token's cancel
  /// error, so `Dio.download` completes with a `DioExceptionType.cancel`.
  Stream<Uint8List> _chunkedStream(_ScriptedBytes scripted) async* {
    final bytes = scripted.bytes;
    final chunkSize = scripted.chunkSize ?? bytes.length;
    var offset = 0;
    while (offset < bytes.length) {
      if (scripted.delay != null) {
        await Future<void>.delayed(scripted.delay!);
      }
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield Uint8List.fromList(bytes.sublist(offset, end));
      offset = end;
    }
  }

  @override
  void close({bool force = false}) {}
}

abstract class _ScriptedResponse {
  const _ScriptedResponse();
}

class _ScriptedBytes extends _ScriptedResponse {
  const _ScriptedBytes(
    this.bytes, {
    this.chunkSize,
    this.delay,
    this.withContentLength = true,
  });

  final List<int> bytes;
  final int? chunkSize;
  final Duration? delay;
  final bool withContentLength;
}

class _ScriptedError extends _ScriptedResponse {
  const _ScriptedError(this.error);

  final Object error;
}
