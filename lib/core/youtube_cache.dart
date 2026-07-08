import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LRU file cache for downloaded audio streams and artwork.
class YoutubeCache {
  YoutubeCache._();
  static final YoutubeCache instance = YoutubeCache._();

  // ═══════════════════════════════════════════════════════════════════
  //  LIMITS
  // ═══════════════════════════════════════════════════════════════════

  static int _maxAudioCacheMB = 5120;
  static int get maxAudioCacheMB => _maxAudioCacheMB;

  static int _maxArtworkCacheMB = 500;
  static int get maxArtworkCacheMB => _maxArtworkCacheMB;

  static Future<void> loadLimits() async {
    final prefs = await SharedPreferences.getInstance();
    _maxAudioCacheMB = prefs.getInt('cache_audio_limit_mb') ?? 5120;
    _maxArtworkCacheMB = prefs.getInt('cache_artwork_limit_mb') ?? 500;
  }

  static Future<void> setAudioLimitMB(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('cache_audio_limit_mb', value);
    _maxAudioCacheMB = value;
  }

  static Future<void> setArtworkLimitMB(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('cache_artwork_limit_mb', value);
    _maxArtworkCacheMB = value;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  CONSTANTS
  // ═══════════════════════════════════════════════════════════════════

  static const Duration _protectWindow = Duration(minutes: 5);
  static const Duration _evictDebounce = Duration(seconds: 30);

  // ═══════════════════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════════════════

  Directory? _audioDir;
  Directory? _artworkDir;

  Directory? get audioDir => _audioDir;
  Directory? get artworkDir => _artworkDir;

  final Map<String, DateTime> _lastAccess = {};
  Future<void>? _initFuture;
  Timer? _evictTimer;

  // ═══════════════════════════════════════════════════════════════════
  //  INIT
  // ═══════════════════════════════════════════════════════════════════

  Future<Directory> _ensureAudioDir() async {
    _initFuture ??= _init();
    await _initFuture;
    return _audioDir!;
  }

  Future<Directory> _ensureArtworkDir() async {
    _initFuture ??= _init();
    await _initFuture;
    return _artworkDir!;
  }

  Future<void> _init() async {
    final tmp = await getTemporaryDirectory();

    _audioDir = Directory(p.join(tmp.path, 'yt_audio_cache'));
    if (!await _audioDir!.exists()) {
      await _audioDir!.create(recursive: true);
    }

    _artworkDir = Directory(p.join(tmp.path, 'yt_artwork_cache'));
    if (!await _artworkDir!.exists()) {
      await _artworkDir!.create(recursive: true);
    }

    await for (final entity in _audioDir!.list()) {
      if (entity is File) {
        final id = p.basenameWithoutExtension(entity.path);
        final stat = await entity.stat();
        _lastAccess[id] = stat.modified;
      }
    }
    _scheduleEviction();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  FILE ACCESS
  // ═══════════════════════════════════════════════════════════════════

  Future<File> fileFor(
    String id, {
    String extension = 'm4a',
    CacheType type = CacheType.audio,
  }) async {
    final dir = type == CacheType.audio
        ? await _ensureAudioDir()
        : await _ensureArtworkDir();
    final file = File(p.join(dir.path, '$id.$extension'));

    if (type == CacheType.audio) {
      _lastAccess[id] = DateTime.now();
      if (await file.exists()) {
        try {
          await file.setLastModified(DateTime.now());
        } catch (_) {}
      }
    }

    _scheduleEviction();
    return file;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  НОВЫЕ МЕТОДЫ — ВСТАВЬ СЮДА (после fileFor, перед EVICTION)
  // ═══════════════════════════════════════════════════════════════════

  /// Проверяет, есть ли трек в аудио-кэше.
  Future<bool> hasFile(String id, {String extension = 'mp3'}) async {
    final dir = await _ensureAudioDir();
    final file = File(p.join(dir.path, '$id.$extension'));
    return file.exists();
  }

  /// Обновляет LRU timestamp (после ручного скачивания).
  void touch(String id) {
    _lastAccess[id] = DateTime.now();
    _scheduleEviction();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  EVICTION
  // ═══════════════════════════════════════════════════════════════════

  void _scheduleEviction() {
    _evictTimer?.cancel();
    _evictTimer = Timer(_evictDebounce, () {
      unawaited(_evictIfNeeded());
    });
  }

  Future<void> _evictIfNeeded() async {
    await _evictAudioIfNeeded();
    await _evictArtworkIfNeeded();
  }

  Future<void> _evictAudioIfNeeded() async {
    if (_audioDir == null || _maxAudioCacheMB == 0) return;

    final limitBytes = _maxAudioCacheMB * 1024 * 1024;
    final files = await _listFilesWithSize(_audioDir!);
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.$2);

    if (totalBytes <= limitBytes) return;

    files.sort((a, b) => a.$3.compareTo(b.$3));

    var overflow = totalBytes - limitBytes;
    final now = DateTime.now();

    for (final (file, size, _) in files) {
      if (overflow <= 0) break;

      final stat = await file.stat();
      if (now.difference(stat.modified) < _protectWindow) continue;

      final fid = p.basenameWithoutExtension(file.path);
      if (await _hasActiveDownload(_audioDir!, fid)) continue;

      try {
        await file.delete();
        _lastAccess.remove(fid);
        overflow -= size;
      } catch (_) {}
    }
  }

  Future<void> _evictArtworkIfNeeded() async {
    if (_artworkDir == null || _maxArtworkCacheMB == 0) return;

    final limitBytes = _maxArtworkCacheMB * 1024 * 1024;
    final files = await _listFilesWithSize(_artworkDir!);
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.$2);

    if (totalBytes <= limitBytes) return;

    files.sort((a, b) => a.$3.compareTo(b.$3));

    var overflow = totalBytes - limitBytes;

    for (final (file, size, _) in files) {
      if (overflow <= 0) break;

      try {
        await file.delete();
        overflow -= size;
      } catch (_) {}
    }
  }

  Future<List<(File, int, DateTime)>> _listFilesWithSize(Directory dir) async {
    final result = <(File, int, DateTime)>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        final stat = await entity.stat();
        result.add((entity, stat.size, stat.modified));
      }
    }
    return result;
  }

  Future<bool> _hasActiveDownload(Directory dir, String id) async {
    for (final ext in const ['m4a', 'webm', 'mp3']) {
      final part = File(p.join(dir.path, '$id.$ext.part'));
      if (await part.exists()) return true;
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  CLEAR
  // ═══════════════════════════════════════════════════════════════════

  Future<void> clearAudioCache() async {
    if (_audioDir == null) return;
    await for (final entity in _audioDir!.list(followLinks: false)) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    _lastAccess.clear();
  }

  Future<void> clearArtworkCache() async {
    if (_artworkDir == null) return;
    await for (final entity in _artworkDir!.list(followLinks: false)) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> clearAllCache() async {
    await clearAudioCache();
    await clearArtworkCache();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  LEGACY
  // ═══════════════════════════════════════════════════════════════════

  Future<void> evict(String id) async {
    if (_audioDir == null) return;
    _lastAccess.remove(id);
    for (final ext in const ['m4a', 'webm', 'mp3']) {
      final f = File(p.join(_audioDir!.path, '$id.$ext'));
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }
}

enum CacheType { audio, artwork }