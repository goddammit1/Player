import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// LRU file cache for downloaded YouTube audio streams.
///
/// just_audio's [LockCachingAudioSource] writes the fully downloaded
/// audio into a file and serves all seek requests from it. We keep that
/// file around in a private temp directory so seeking within a recently
/// played track is instant — but we cap the total number of cached
/// tracks so we don't fill the device storage.
///
/// Eviction policy: simple LRU by last access time. When the cache has
/// more than [maxEntries] files, the oldest are removed.
class YoutubeCache {
  YoutubeCache._();
  static final YoutubeCache instance = YoutubeCache._();

  /// Max number of cached tracks. ~5 tracks * ~5 MB each = ~25 MB.
  /// Bump this if more aggressive caching is desired.
  static const int maxEntries = 5;

  Directory? _dir;
  // videoId -> last access time. Persisted via file mtime on disk too,
  // but we also keep this in-memory for fast lookup.
  final Map<String, DateTime> _lastAccess = {};
  Future<void>? _initFuture;

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
    await _evictIfNeeded();
  }

  /// Returns the cache file for the given video id. The file may not
  /// exist yet — [LockCachingAudioSource] will create and fill it.
  /// Updates the LRU timestamp.
  Future<File> fileFor(String videoId, {String extension = 'm4a'}) async {
    final dir = await _ensureDir();
    final file = File(p.join(dir.path, '$videoId.$extension'));
    _lastAccess[videoId] = DateTime.now();
    // Touch the file mtime so subsequent process restarts see correct
    // LRU order even before our in-memory map is rebuilt.
    if (await file.exists()) {
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {
        // Not all platforms support setLastModified; best-effort only.
      }
    }
    // Evict in background so we don't block the audio start.
    unawaited(_evictIfNeeded());
    return file;
  }

  Future<void> _evictIfNeeded() async {
    final dir = _dir;
    if (dir == null) return;

    final entries = _lastAccess.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    final overflow = entries.length - maxEntries;
    if (overflow <= 0) return;

    for (var i = 0; i < overflow; i++) {
      final id = entries[i].key;
      _lastAccess.remove(id);
      // The extension is unknown without checking — try both common ones.
      for (final ext in const ['m4a', 'webm']) {
        final f = File(p.join(dir.path, '$id.$ext'));
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {
            // ignore: file might be locked by an active download
          }
        }
      }
    }
  }

  /// Forget a specific video. Useful when the cached file is broken
  /// (e.g. partial download from a previous session that we don't want
  /// to serve as a finished file).
  Future<void> evict(String videoId) async {
    final dir = await _ensureDir();
    _lastAccess.remove(videoId);
    for (final ext in const ['m4a', 'webm']) {
      final f = File(p.join(dir.path, '$videoId.$ext'));
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }
}
