import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Дисковый кэш приложения.
///
/// Аудио (`yt_audio_cache`): LRU-кэш по mtime файлов с лимитом в МБ.
/// Сюда пишут LockCachingAudioSource (muzmo/soundcloud — всегда mp3) и
/// ручное скачивание из шторки трека. Файлы m4a/webm — легаси от
/// отключённого YouTube-источника: они по-прежнему учитываются в
/// размере и эвиктятся.
///
/// Обложки: их хранит CachedNetworkImage (flutter_cache_manager) в
/// `libCachedImageData`. Мы этот каталог НЕ наполняем — только меряем
/// и ограничиваем по размеру. Удалять файлы «за спиной» cache manager
/// безопасно: при промахе обложка просто скачается заново.
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
  //  CACHE ID / EXTENSIONS
  // ═══════════════════════════════════════════════════════════════════

  /// Расширения, с которыми аудио может лежать в кэше.
  /// mp3 — актуальные источники (muzmo, soundcloud);
  /// m4a/webm — легаси-файлы отключённого YouTube-источника.
  static const List<String> audioExtensions = ['mp3', 'm4a', 'webm'];

  /// Единственная точка формирования cache id по треку.
  /// Раньше эта логика дублировалась в PlayerService и
  /// track_settings_sheet и могла разъехаться при добавлении источника.
  static String cacheIdFor({
    required String sourceId,
    required String trackId,
  }) {
    switch (sourceId) {
      case 'muzmo':
        return 'muzmo_$trackId';
      case 'soundcloud':
        return 'soundcloud_$trackId';
      default:
        return trackId;
    }
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

  /// Каталог дискового кэша CachedNetworkImage (`libCachedImageData`).
  Directory? get artworkDir => _artworkDir;

  Future<void>? _initFuture;
  Timer? _evictTimer;

  /// id трека, который играет прямо сейчас: его файл нельзя эвиктить
  /// или удалять при «Clear audio cache» — LockCachingAudioSource держит
  /// его открытым, удаление на лету роняет воспроизведение.
  String? _protectedId;

  /// id вручную скачанных («закреплённых») треков. Они лежат в общем
  /// аудио-каталоге (чтобы LockCachingAudioSource играл их из кэша, в т.ч.
  /// офлайн), но LRU-эвиктор их не трогает.
  final Set<String> _pinnedIds = <String>{};
  bool _pinnedLoaded = false;

  /// Отмечает трек как играющий (защита от эвикта). null — снять защиту.
  void setProtectedId(String? id) => _protectedId = id;

  bool isPinned(String id) => _pinnedIds.contains(id);

  // ═══════════════════════════════════════════════════════════════════
  //  INIT
  // ═══════════════════════════════════════════════════════════════════

  Future<Directory> _ensureAudioDir() async {
    _initFuture ??= _init();
    await _initFuture;
    return _audioDir!;
  }

  /// Инициализирует пути кэша (используется страницей статистики).
  Future<Directory?> ensureArtworkDir() async {
    _initFuture ??= _init();
    await _initFuture;
    return _artworkDir;
  }

  Future<void> _init() async {
    final tmp = await getTemporaryDirectory();

    _audioDir = Directory(p.join(tmp.path, 'yt_audio_cache'));
    if (!await _audioDir!.exists()) {
      await _audioDir!.create(recursive: true);
    }

    // Каталог создаёт сам flutter_cache_manager — не создаём за него.
    _artworkDir = Directory(p.join(tmp.path, 'libCachedImageData'));

    await _loadPinnedIds();

    _scheduleEviction();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  PINNED (ручные загрузки)
  // ═══════════════════════════════════════════════════════════════════

  static const String _pinnedPrefsKey = 'cache_pinned_ids';

  Future<void> _loadPinnedIds() async {
    if (_pinnedLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _pinnedIds
        ..clear()
        ..addAll(prefs.getStringList(_pinnedPrefsKey) ?? const <String>[]);
    } catch (_) {}
    _pinnedLoaded = true;
  }

  Future<void> _persistPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinnedPrefsKey, _pinnedIds.toList());
    } catch (_) {}
  }

  /// Закрепляет трек (ручная загрузка): защищает от LRU-эвикта.
  Future<void> pin(String id) async {
    await _loadPinnedIds();
    if (_pinnedIds.add(id)) {
      await _persistPinnedIds();
    }
  }

  /// Снимает закрепление.
  Future<void> unpin(String id) async {
    await _loadPinnedIds();
    if (_pinnedIds.remove(id)) {
      await _persistPinnedIds();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  FILE ACCESS
  // ═══════════════════════════════════════════════════════════════════

  Future<File> fileFor(String id, {String extension = 'mp3'}) async {
    final dir = await _ensureAudioDir();
    final file = File(p.join(dir.path, '$id.$extension'));

    // LRU: единственный источник истины — mtime файла.
    if (await file.exists()) {
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {}
    }

    _scheduleEviction();
    return file;
  }

  /// Есть ли трек в аудио-кэше (с любым известным расширением).
  Future<bool> hasFile(String id) async => (await findFile(id)) != null;

  /// Ищет файл трека в кэше независимо от расширения.
  Future<File?> findFile(String id) async {
    final dir = await _ensureAudioDir();
    for (final ext in audioExtensions) {
      final f = File(p.join(dir.path, '$id.$ext'));
      if (await f.exists()) return f;
    }
    return null;
  }

  /// Обновляет LRU timestamp (mtime файла) — например, после ручного
  /// скачивания, чтобы эвиктор не удалил свежескачанный трек.
  Future<void> touch(String id) async {
    final f = await findFile(id);
    if (f != null) {
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
    }
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
      if (fid == _protectedId) continue;
      if (_pinnedIds.contains(fid)) continue;
      if (await _hasActiveDownload(_audioDir!, fid)) continue;

      try {
        await file.delete();
        overflow -= size;
      } catch (_) {}
    }
  }

  /// Ограничивает по размеру дисковый кэш CachedNetworkImage.
  /// Раньше здесь эвиктился `yt_artwork_cache` — каталог, в который
  /// никто никогда не писал, т.е. лимит обложек не работал вовсе.
  Future<void> _evictArtworkIfNeeded() async {
    final dir = _artworkDir;
    if (dir == null || _maxArtworkCacheMB == 0) return;
    if (!await dir.exists()) return;

    final limitBytes = _maxArtworkCacheMB * 1024 * 1024;
    final files = await _listFilesWithSize(dir);
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
    for (final ext in audioExtensions) {
      final part = File(p.join(dir.path, '$id.$ext.part'));
      if (await part.exists()) return true;
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  CLEAR
  // ═══════════════════════════════════════════════════════════════════

  Future<void> clearAudioCache() async {
    await _ensureAudioDir();
    if (_audioDir == null) return;
    await for (final entity in _audioDir!.list(followLinks: false)) {
      if (entity is File) {
        // Не трогаем файл играющего трека — он открыт плеером.
        final fid = p.basenameWithoutExtension(entity.path);
        if (fid == _protectedId) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    _pinnedIds.clear();
    await _persistPinnedIds();
  }

  /// Чистит дисковый кэш обложек CachedNetworkImage. RAM ImageCache
  /// Flutter вызывающая сторона чистит сама (PaintingBinding).
  Future<void> clearArtworkCache() async {
    final dir = await ensureArtworkDir();
    if (dir == null || !await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
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
  //  EVICT ONE
  // ═══════════════════════════════════════════════════════════════════

  Future<void> evict(String id) async {
    final dir = await _ensureAudioDir();
    for (final ext in audioExtensions) {
      final f = File(p.join(dir.path, '$id.$ext'));
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    await unpin(id);
  }
}
