import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// LRU file cache for downloaded audio streams.
///
/// just_audio's `LockCachingAudioSource` writes the fully downloaded
/// audio into a file and serves all seek requests from it. We keep that
/// file around in a private temp directory so seeking within (and
/// re-listening to) a recently played track is instant — but we cap the
/// total number of cached tracks so we don't fill the device storage.
///
/// Eviction policy: simple LRU by last access time. When the cache has
/// more than [maxEntries] files, the oldest are removed.
///
/// Important behavioural details for smooth playback:
///
/// 1. **Eviction is debounced.** Calling [fileFor] does NOT immediately
///    delete the old files. We schedule a single cleanup pass on a
///    background timer ([_evictDebounce]). This means switching tracks
///    rapidly (skip, skip, skip) doesn't trigger N synchronous
///    `File.delete()` calls right while ExoPlayer is buffering the new
///    track on the main isolate.
///
/// 2. **Protected window.** We never delete a file that was touched
///    within the last [_protectWindow] — it is most likely the file
///    that is *currently playing* or *just played*. Even if it's LRU
///    by raw timestamp, deleting it under ExoPlayer's feet causes
///    `EBADF` and audible glitches.
///
/// 3. **Cache is process-shared.** Both YouTube and Muzmo sources call
///    `fileFor(...)` with their own namespaced ids (`'muzmo_<id>'`,
///    raw YouTube id). The LRU is unified, so heavy usage of one
///    source doesn't starve the other artificially.
class YoutubeCache {
  YoutubeCache._();
  static final YoutubeCache instance = YoutubeCache._();

  /// Max number of cached tracks. With mp3 320 kbps that's ~30 * 5 MB
  /// = ~150 MB peak — negligible for any modern device, enough so that
  /// during a normal listening session we (almost) never re-download.
  static const int maxEntries = 30;

  /// Files touched within this window are considered "hot" and are
  /// never evicted, even if they are technically the oldest entries.
  /// Prevents deleting the currently-playing file under ExoPlayer.
  static const Duration _protectWindow = Duration(minutes: 5);

  /// Eviction passes are coalesced with this debounce so that a burst
  /// of `fileFor` calls (e.g. fast-skip through a queue) produces at
  /// most one cleanup pass.
  static const Duration _evictDebounce = Duration(seconds: 30);

  Directory? _dir;
  // namespaced id (e.g. 'muzmo_12345' or YouTube videoId) -> last access time.
  // Persisted via file mtime on disk too, but kept in-memory for fast lookup.
  final Map<String, DateTime> _lastAccess = {};
  Future<void>? _initFuture;
  Timer? _evictTimer;

  Future<Directory> _ensureDir() async {
    _initFuture ??= _init();
    await _initFuture;
    return _dir!;
  }

  Future<void> _init() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'yt_audio_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    // Rebuild the lastAccess map from existing files on disk.
    await for (final entity in dir.list()) {
      if (entity is File) {
        final id = p.basenameWithoutExtension(entity.path);
        final stat = await entity.stat();
        _lastAccess[id] = stat.modified;
      }
    }
    _scheduleEviction();
  }

  /// Returns the cache file for the given track id (already namespaced
  /// by the caller, e.g. `'muzmo_<id>'`). The file may not exist yet —
  /// [LockCachingAudioSource] will create and fill it. Updates the LRU
  /// timestamp and schedules a debounced cleanup.
  Future<File> fileFor(String id, {String extension = 'm4a'}) async {
    final dir = await _ensureDir();
    final file = File(p.join(dir.path, '$id.$extension'));
    _lastAccess[id] = DateTime.now();
    // Touch the file mtime so subsequent process restarts see correct
    // LRU order even before our in-memory map is rebuilt.
    if (await file.exists()) {
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {
        // Not all platforms support setLastModified; best-effort only.
      }
    }
    _scheduleEviction();
    return file;
  }

  /// Restart the debounce timer. Multiple `fileFor` calls within
  /// [_evictDebounce] coalesce into a single eviction pass.
  void _scheduleEviction() {
    _evictTimer?.cancel();
    _evictTimer = Timer(_evictDebounce, () {
      unawaited(_evictIfNeeded());
    });
  }

  Future<void> _evictIfNeeded() async {
    final dir = _dir;
    if (dir == null) return;

    final now = DateTime.now();
    // Sort oldest -> newest.
    final entries = _lastAccess.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    var overflow = entries.length - maxEntries;
    if (overflow <= 0) return;

    for (final e in entries) {
      if (overflow <= 0) break;
      // Skip "hot" files — most likely currently playing.
      if (now.difference(e.value) < _protectWindow) continue;

      final id = e.key;
      _lastAccess.remove(id);
      for (final ext in const ['m4a', 'webm', 'mp3']) {
        final f = File(p.join(dir.path, '$id.$ext'));
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {
            // ignore: file might be locked by an active download
          }
        }
      }
      overflow--;
    }
  }

  /// Forget a specific track. Useful when the cached file is broken
  /// (e.g. partial download from a previous session that we don't want
  /// to serve as a finished file).
  Future<void> evict(String id) async {
    final dir = await _ensureDir();
    _lastAccess.remove(id);
    for (final ext in const ['m4a', 'webm', 'mp3']) {
      final f = File(p.join(dir.path, '$id.$ext'));
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }
}
