import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../sources/artwork_provider.dart';
import 'database/app_database.dart';
import 'artwork_helper.dart';

/// Аудио-файл в дисковом кэше (без `.part`/`.mime`-спутников).
class CachedAudioFile {
  const CachedAudioFile({
    required this.cacheId,
    required this.file,
    required this.sizeBytes,
    required this.modified,
    required this.pinned,
  });

  final String cacheId;
  final File file;
  final int sizeBytes;

  /// mtime файла: LRU-метка (обновляется при каждом открытии).
  final DateTime modified;
  final bool pinned;
}

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
    try {
      final audioStr = await AppDatabase.instance.getSetting('cache_audio_limit_mb');
      final artworkStr = await AppDatabase.instance.getSetting('cache_artwork_limit_mb');
      _maxAudioCacheMB = int.tryParse(audioStr ?? '') ?? _maxAudioCacheMB;
      _maxArtworkCacheMB = int.tryParse(artworkStr ?? '') ?? _maxArtworkCacheMB;
    } catch (_) {}
  }

  static Future<void> setAudioLimitMB(int value) async {
    try {
      await AppDatabase.instance.setSetting('cache_audio_limit_mb', value.toString());
    } catch (_) {}
    _maxAudioCacheMB = value;
  }

  static Future<void> setArtworkLimitMB(int value) async {
    try {
      await AppDatabase.instance.setSetting('cache_artwork_limit_mb', value.toString());
    } catch (_) {}
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

  /// Обратная операция к [cacheIdFor]: источник и id трека по cache id.
  /// Для id без известного префикса — легаси YouTube (id = cache id).
  static ({String sourceId, String trackId}) parseCacheId(String cacheId) {
    for (final sourceId in const ['muzmo', 'soundcloud']) {
      final prefix = '${sourceId}_';
      if (cacheId.startsWith(prefix) && cacheId.length > prefix.length) {
        return (sourceId: sourceId, trackId: cacheId.substring(prefix.length));
      }
    }
    return (sourceId: 'youtube', trackId: cacheId);
  }

  /// Удобный хелпер: файл кэша для трека с учётом его источника.
  /// Попутно запоминает метаданные трека в индексе (см. [registerTrack]).
  ///
  /// Источники зовут его перед стримингом через LockCachingAudioSource,
  /// т.е. когда файла ещё нет: дата кэширования сбрасывается на «сейчас»,
  /// иначе трек, однажды пропущенный и докачанный через месяц, попал бы
  /// в группу дня первой попытки.
  Future<File> fileForTrack(
    Track track, {
    String extension = 'mp3',
  }) {
    unawaited(registerTrack(track, resetCachedAt: true));
    return fileFor(
      cacheIdFor(sourceId: track.sourceId, trackId: track.id),
      extension: extension,
    );
  }

  /// Запоминает название/исполнителя трека для списка кэшированных
  /// треков: по имени файла (`muzmo_<id>.mp3`) их не восстановить.
  /// Ошибки БД не мешают кэшированию. [cachedAt] — для дозаписи индекса
  /// по уже лежащему в кэше файлу (по умолчанию — сейчас); дата у
  /// существующей записи меняется только с [resetCachedAt].
  Future<void> registerTrack(
    Track track, {
    DateTime? cachedAt,
    bool resetCachedAt = false,
  }) async {
    try {
      await AppDatabase.instance.upsertAudioCacheEntry(
        cacheIdFor(sourceId: track.sourceId, trackId: track.id),
        track,
        cachedAt: cachedAt,
        resetCachedAt: resetCachedAt,
      );
    } catch (_) {}
  }

  /// Удаляет записи индекса [ids], у которых нет файла в кэше: загрузка
  /// не завершилась, файл вычистила ОС, или запись досталась гонке с
  /// очисткой. Идущие загрузки (`.part`) и играющий трек не трогаются.
  Future<void> forgetMissing(Iterable<String> ids) async {
    final dir = await _ensureAudioDir();
    final missing = <String>[];
    for (final id in ids) {
      if (id == _protectedId) continue;
      if (await findFile(id) != null) continue;
      if (await _hasActiveDownload(dir, id)) continue;
      missing.add(id);
    }
    await _forgetIndexEntries(missing);
  }

  /// Удаляет трек из кэша по запросу пользователя. В отличие от [evict]
  /// не трогает файл играющего трека и сбрасывает закрепление и индекс
  /// только если файл действительно удалён (на Windows открытый файл
  /// удалить нельзя). Возвращает false, если трек остался в кэше.
  Future<bool> removeTrackFile(String id) async {
    if (id == _protectedId) return false;
    final dir = await _ensureAudioDir();
    var removed = true;
    for (final ext in audioExtensions) {
      final f = File(p.join(dir.path, '$id.$ext'));
      if (!await f.exists()) continue;
      try {
        await f.delete();
      } catch (_) {
        removed = false;
      }
    }
    if (!removed) return false;
    await unpin(id);
    await _forgetIndexEntries([id]);
    return true;
  }

  /// Аудио-файлы в кэше. Незавершённые загрузки (`.part`) и служебные
  /// файлы just_audio (`.mime`) не попадают в список.
  Future<List<CachedAudioFile>> listAudioFiles() async {
    final dir = await _ensureAudioDir();
    await _loadPinnedIds();
    final result = <CachedAudioFile>[];
    try {
      for (final (file, size, modified) in await _listFilesWithSize(dir)) {
        final ext = p.extension(file.path).replaceFirst('.', '');
        if (!audioExtensions.contains(ext)) continue;
        final id = p.basenameWithoutExtension(file.path);
        result.add(CachedAudioFile(
          cacheId: id,
          file: file,
          sizeBytes: size,
          modified: modified,
          pinned: _pinnedIds.contains(id),
        ));
      }
    } catch (_) {}
    return result;
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

  /// Guard эвикции: таймер и ручные вызовы не должны сканировать каталог
  /// конкурентно. Если прогон уже идёт, новый вызов получает тот же Future
  /// (см. [_evictIfNeeded]).
  Future<void>? _evictInFlight;

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
  //  TEST HOOKS
  // ═══════════════════════════════════════════════════════════════════

  /// Тестовый хук: подменяет каталог аудио-кэша напрямую, минуя
  /// path_provider. После теста вернуть `null`.
  @visibleForTesting
  void setAudioDirForTesting(Directory? dir) => _audioDir = dir;

  /// Тестовый хук: подменяет каталог обложек CachedNetworkImage
  /// (`libCachedImageData`) напрямую, минуя path_provider. После теста
  /// вернуть `null`.
  @visibleForTesting
  void setArtworkDirForTesting(Directory? dir) => _artworkDir = dir;

  /// Тестовый хук: немедленный запуск проверки эвикции — без
  /// 30-секундного дебаунса [_evictDebounce].
  @visibleForTesting
  Future<void> runEvictionForTesting() => _evictIfNeeded();

  /// Тестовый хук: отменяет отложенный таймер эвикции, чтобы в конце
  /// теста не оставалось pending-таймеров.
  @visibleForTesting
  void cancelPendingEvictionForTesting() => _evictTimer?.cancel();

  // ═══════════════════════════════════════════════════════════════════
  //  INIT
  // ═══════════════════════════════════════════════════════════════════

  Future<Directory> _ensureAudioDir() async {
    // Если каталог уже задан (в т.ч. тестовым хуком) — не дёргаем
    // path_provider повторно.
    if (_audioDir != null) return _audioDir!;
    _initFuture ??= _init();
    await _initFuture;
    return _audioDir!;
  }

  /// Инициализирует пути кэша (используется страницей статистики).
  Future<Directory?> ensureArtworkDir() async {
    if (_artworkDir != null) return _artworkDir;
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
      final raw = await AppDatabase.instance.getSetting(_pinnedPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<String>();
        _pinnedIds
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    _pinnedLoaded = true;
  }

  Future<void> _persistPinnedIds() async {
    try {
      await AppDatabase.instance.setSetting(
        _pinnedPrefsKey,
        jsonEncode(_pinnedIds.toList()),
      );
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
    } else {
      // Новый кэш-файл появится — каталог изменится, планируем эвикцию.
      // Простое открытие существующего файла для воспроизведения каталог
      // не меняет, поэтому скан не планируем.
      _scheduleEviction();
    }

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

  Future<void> _evictIfNeeded() {
    // Единый guard: пока один прогон (таймер/тест/ручной вызов) идёт,
    // второй получает тот же Future вместо параллельного сканирования.
    final inFlight = _evictInFlight;
    if (inFlight != null) return inFlight;

    final run = _runEviction();
    _evictInFlight = run;
    unawaited(run.whenComplete(() {
      if (identical(_evictInFlight, run)) _evictInFlight = null;
    }));
    return run;
  }

  Future<void> _runEviction() async {
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
    final evicted = <String>[];

    // mtime берём из листинга — повторный stat() на каждый кандидат не нужен.
    for (final (file, size, modified) in files) {
      if (overflow <= 0) break;

      if (now.difference(modified) < _protectWindow) continue;

      final fid = p.basenameWithoutExtension(file.path);
      if (fid == _protectedId) continue;
      if (_pinnedIds.contains(fid)) continue;
      if (await _hasActiveDownload(_audioDir!, fid)) continue;

      try {
        await file.delete();
        overflow -= size;
        evicted.add(fid);
      } catch (_) {}
    }
    await _forgetIndexEntries(evicted);
  }

  Future<void> _forgetIndexEntries(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      await AppDatabase.instance.removeAudioCacheEntries(ids);
    } catch (_) {}
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
    try {
      await AppDatabase.instance.clearAudioCacheIndex(keep: _protectedId);
    } catch (_) {}
  }

  /// Чистит дисковый кэш обложек CachedNetworkImage, сбрасывает
  /// SQLite-кэш URL обложек (artwork_v3_*) и in-memory кэш ArtworkProvider,
  /// чтобы обложки были перезапрошены заново при следующем воспроизведении.
  /// RAM ImageCache Flutter вызывающая сторона чистит сама (PaintingBinding).
  Future<void> clearArtworkCache() async {
    final dir = await ensureArtworkDir();
    if (dir != null && await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }

    // Очищаем SQLite-кэш URL обложек и in-memory кэш ArtworkProvider.
    try {
      await AppDatabase.instance.clearArtworkCacheDb();
    } catch (_) {}
    ArtworkProvider.instance.clearMemCache();
  }

  /// Очищает абсолютно всё: аудио, обложки с диска, SQLite-кэш URL обложек,
  /// in-memory кэш ArtworkProvider.
  Future<void> clearAllCache() async {
    await clearAudioCache();
    await clearArtworkCache();
    // Дополнительно чистим custom artwork cache и любые оставшиеся кэш-записи.
    try {
      await AppDatabase.instance.clearCacheData();
    } catch (_) {}
    ArtworkProvider.instance.clearMemCache();
    // Полная очистка кастомных обложек: файлы на диске + in-memory кэш.
    // SQLite-ключи custom_art_v* уже удалены clearCacheData выше, но оставались
    // файлы на диске и RAM-кэш ArtworkHelper, из-за чего обложка «висела» до
    // рестарта и файлы оставались сиротами. Теперь — как при первом запуске.
    await ArtworkHelper.clearAllCustomArtwork();
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
    await _forgetIndexEntries([id]);
  }
}
