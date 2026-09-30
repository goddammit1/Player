import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../sources/soulseek_source.dart';
import '../sources/source_registry.dart';
import 'youtube_cache.dart';

/// Status of a single track inside a batch caching run.
enum PlaylistCacheTrackStatus { pending, downloading, done, skipped, failed }

/// Final report of a batch caching run.
class PlaylistCacheResult {
  const PlaylistCacheResult({
    required this.downloaded,
    required this.skippedCached,
    required this.skippedDisabled,
    required this.failed,
    required this.cancelled,
  });

  /// Successfully downloaded and pinned tracks.
  final int downloaded;

  /// Tracks that were already present in the cache (re-pinned + touched).
  final int skippedCached;

  /// Tracks whose source is disabled (e.g. youtube) — never attempted.
  final int skippedDisabled;

  /// Tracks that failed to resolve or download.
  final int failed;

  /// Whether the run was interrupted by the user via [CancelToken].
  final bool cancelled;

  /// Total number of tracks accounted for (including disabled ones).
  int get total => downloaded + skippedCached + skippedDisabled + failed;
}

/// Progress snapshot emitted while a batch caching run is in flight.
class PlaylistCacheProgress {
  const PlaylistCacheProgress({
    required this.completed,
    required this.total,
    required this.currentTitle,
    required this.currentProgress,
  });

  /// Tracks processed so far (done + skipped + failed).
  final int completed;

  /// Tracks to process (disabled sources are excluded up front, so the
  /// progress bar does not stall on unreachable tracks).
  final int total;

  /// Title of the track currently being processed ('' when idle).
  final String currentTitle;

  /// Progress of the current track in the range 0.0..1.0, or null when the
  /// server did not report a content length.
  final double? currentProgress;
}

/// Factory for the [Dio] instance used to download tracks. Injectable so
/// tests can substitute an adapter-backed fake without touching the network.
typedef PlaylistCacheDioFactory = Dio Function();

/// Batch-caches playlist tracks into the disk cache ([YoutubeCache]).
///
/// Pure Dart — no Flutter UI imports — so unit tests do not need widgets.
/// Mirrors the single-track download flow of the track settings sheet:
/// `resolveStreamUrl` → `fileFor(...).part` → `Dio().download` → rename →
/// `pin`. Runs strictly sequentially to avoid hammering the network and to
/// keep progress/cancellation trivially consistent.
class PlaylistCacheService {
  PlaylistCacheService({
    YoutubeCache? cache,
    SourceRegistry? registry,
    PlaylistCacheDioFactory? dioFactory,
  })  : _cache = cache ?? YoutubeCache.instance,
        _registry = registry ?? SourceRegistry.instance,
        _dioFactory = dioFactory ?? _defaultDio;

  final YoutubeCache _cache;
  final SourceRegistry _registry;
  final PlaylistCacheDioFactory _dioFactory;

  static Dio _defaultDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

  /// Caches all reachable tracks from [tracks].
  ///
  /// Behaviour:
  /// - tracks whose source is disabled (`SourceRegistry.isDisabled`) are
  ///   filtered out up front and counted in
  ///   [PlaylistCacheResult.skippedDisabled]; the progress `total` only
  ///   covers the remaining queue;
  /// - soulseek tracks are handled source-aware (see [_cacheSoulseekTrack]):
  ///   their `resolveStreamUrl` returns a LOCAL path of the native
  ///   soulseek_cache, not an HTTP URL, so dio.download must not be used;
  /// - tracks already present in the cache are skipped without network
  ///   access, but re-pinned and touched (counts as
  ///   [PlaylistCacheResult.skippedCached]);
  /// - a failure of a single track does NOT abort the batch: the partial
  ///   `.part` file is removed on a best-effort basis, the track is counted
  ///   as failed and the loop continues;
  /// - [cancelToken] is a Dio [CancelToken]: cancellation surfaces as a
  ///   [DioException] with `type == DioExceptionType.cancel`, which is
  ///   translated into `result.cancelled == true` (already downloaded tracks
  ///   stay pinned);
  /// - [onProgress] fires when the current track changes and on every
  ///   `onReceiveProgress` chunk.
  Future<PlaylistCacheResult> cacheTracks(
    List<Track> tracks, {
    CancelToken? cancelToken,
    void Function(PlaylistCacheProgress progress)? onProgress,
  }) async {
    final queue = <Track>[];
    var skippedDisabled = 0;
    for (final t in tracks) {
      if (_registry.isDisabled(t.sourceId)) {
        skippedDisabled++;
      } else {
        queue.add(t);
      }
    }

    final total = queue.length;
    var downloaded = 0;
    var skippedCached = 0;
    var failed = 0;
    var cancelled = false;

    void emit(String currentTitle, double? currentProgress) {
      onProgress?.call(
        PlaylistCacheProgress(
          completed: downloaded + skippedCached + failed,
          total: total,
          currentTitle: currentTitle,
          currentProgress: currentProgress,
        ),
      );
    }

    for (final track in queue) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }

      emit(track.title, null);

      // Source-aware branch: soulseek tracks live in the native
      // soulseek_cache managed by SoulseekCacheManager, not in
      // [YoutubeCache]. resolveStreamUrl returns a local file path (the
      // native download has already completed by the time it returns), so
      // downloading it via dio would throw. Mirror the single-track flow
      // (PLAYER-DL-01 in track_settings_sheet.dart): cache check via
      // getCacheEntry, then native startDownload + wait for completion.
      if (track.sourceId == SoulseekSource.sourceId) {
        final outcome = await _cacheSoulseekTrack(track);
        switch (outcome) {
          case _SoulseekOutcome.cached:
            skippedCached++;
            emit(track.title, 1.0);
          case _SoulseekOutcome.downloaded:
            downloaded++;
            emit(track.title, 1.0);
          case _SoulseekOutcome.failed:
            failed++;
            emit(track.title, null);
        }
        continue;
      }

      final cacheId = YoutubeCache.cacheIdFor(
        sourceId: track.sourceId,
        trackId: track.id,
      );

      // Already on disk: re-pin (in case it was evicted from the pinned set)
      // and refresh the LRU timestamp, no network access.
      if (await _cache.hasFile(cacheId)) {
        await _cache.pin(cacheId);
        await _cache.touch(cacheId);
        skippedCached++;
        emit(track.title, 1.0);
        continue;
      }

      final file = await _cache.fileFor(cacheId, extension: 'mp3');
      final partPath = '${file.path}.part';

      try {
        final url = await _registry.require(track.sourceId).resolveStreamUrl(track);

        final dio = _dioFactory();
        try {
          await dio.download(
            url,
            partPath,
            cancelToken: cancelToken,
            onReceiveProgress: (received, totalBytes) {
              emit(
                track.title,
                totalBytes > 0
                    ? (received / totalBytes).clamp(0.0, 1.0)
                    : null,
              );
            },
          );
        } finally {
          dio.close();
        }

        await File(partPath).rename(file.path);
        await _cache.pin(cacheId);
        downloaded++;
        emit(track.title, 1.0);
      } on DioException catch (e) {
        await _deletePart(partPath);
        if (e.type == DioExceptionType.cancel) {
          cancelled = true;
          break;
        }
        failed++;
        emit(track.title, null);
      } catch (_) {
        // Resolve error, StateError for unregistered source, rename
        // failure, etc. — the batch must go on.
        await _deletePart(partPath);
        failed++;
        emit(track.title, null);
      }
    }

    return PlaylistCacheResult(
      downloaded: downloaded,
      skippedCached: skippedCached,
      skippedDisabled: skippedDisabled,
      failed: failed,
      cancelled: cancelled,
    );
  }

  /// Source-aware caching of a soulseek track (PLAYER-DL-01 pattern).
  ///
  /// Soulseek files live in the native soulseek_cache, not in
  /// [YoutubeCache] — no dio download and no YoutubeCache pin here (the
  /// native cache manages its own lifecycle/LRU).
  ///
  /// - Native cache hit (`getCacheEntry(cacheKey).complete`) →
  ///   [_SoulseekOutcome.cached];
  /// - otherwise `resolveStreamUrl` starts the native download and waits
  ///   for completion (`_waitForDownloadComplete`: transfer events +
  ///   polling fallback + timeout) → [_SoulseekOutcome.downloaded];
  /// - any error — including tracks from the cache list that only carry
  ///   `extra.cacheKey` without the peerUsername/remoteFilename/sizeBytes
  ///   triad and whose native file was deleted (`StateError` from
  ///   cacheKey computation) — is logged and mapped to
  ///   [_SoulseekOutcome.failed] with a real cause, the batch goes on.
  Future<_SoulseekOutcome> _cacheSoulseekTrack(Track track) async {
    final source = _registry.get(SoulseekSource.sourceId);
    if (source is! SoulseekSource) {
      if (kDebugMode) {
        debugPrint(
          '[PlaylistCache] soulseek source is not registered — skipping '
          '"${track.globalId}"',
        );
      }
      return _SoulseekOutcome.failed;
    }

    try {
      // 1. Already in the native cache? No network access.
      final cacheKey = source.cacheKeyFor(track);
      if (cacheKey != null) {
        final entry = await source.getCacheEntry(cacheKey);
        if (entry != null && entry.complete) {
          return _SoulseekOutcome.cached;
        }
      }

      // 2. Native download + wait for completion (resolveStreamUrl
      //    encapsulates startDownload and _waitForDownloadComplete; for
      //    cache-list tracks it returns the local path on a cache hit).
      await source.resolveStreamUrl(track);
      return _SoulseekOutcome.downloaded;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[PlaylistCache] soulseek caching failed for "${track.globalId}": $e',
        );
      }
      return _SoulseekOutcome.failed;
    }
  }

  static Future<void> _deletePart(String partPath) async {
    try {
      final part = File(partPath);
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }
}

/// Outcome of caching a single soulseek track.
enum _SoulseekOutcome { cached, downloaded, failed }
