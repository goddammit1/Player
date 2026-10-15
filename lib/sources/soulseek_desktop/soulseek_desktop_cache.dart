// lib/sources/soulseek_desktop/soulseek_desktop_cache.dart
//
// Кэш скачанных файлов Soulseek на Windows — порт SoulseekCacheManager.kt.
//
// Раскладка (по образцу slskd — недокачанное отдельно от готового):
//  - во время загрузки: `<cacheDir>/incomplete/<cacheKey>.part`;
//  - после проверки мостом и публикации: `<cacheDir>/<cacheKey>.<ext>`.
// cacheKey = sha256(source, peer, remote path, size), поэтому чужой `.part`
// при resume подхватиться не может.
//
// Отличие от Android: публикацию (.part → final) делает не мост, а этот класс,
// после того как прокси закрыл свои читатели `.part` (Windows не даёт
// переименовать открытый файл).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../growing_file_reader.dart';
import '../soulseek_models.dart';
import 'soulseek_desktop_store.dart';

class SoulseekDesktopCache {
  SoulseekDesktopCache({
    required this.store,
    required this.cacheDir,
    int maxCacheSizeBytes = defaultMaxCacheSizeBytes,
    this.publishWait = const Duration(seconds: 5),
  }) : _maxCacheSizeBytes = maxCacheSizeBytes;

  /// 1 GiB — как сид max_cache_size в soulseek.db.
  static const int defaultMaxCacheSizeBytes = 1024 * 1024 * 1024;

  final SoulseekDesktopStore store;
  final String cacheDir;

  /// Сколько ждать, пока читатели закроют `.part`, прежде чем публиковать
  /// копией (переименование открытого файла на Windows невозможно).
  final Duration publishWait;

  int _maxCacheSizeBytes;
  int get maxCacheSizeBytes => _maxCacheSizeBytes;

  /// Отложенные удаления (путь → номер): новая загрузка того же ключа
  /// отменяет удаление, запланированное для прошлой.
  final Map<String, int> _pendingDeletes = {};
  int _deleteSeq = 0;

  String get incompleteDir => p.join(cacheDir, 'incomplete');

  /// Путь `.part` для загрузки [cacheKey].
  String partPath(String cacheKey) =>
      p.join(incompleteDir, '${_requireKey(cacheKey)}.part');

  /// `.part` с данными (resume) или null.
  Future<File?> existingPart(String cacheKey) async {
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) return null;
    final file = File(p.join(incompleteDir, '$key.part'));
    try {
      return await file.length() > 0 ? file : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Завершённый файл кэша или null. Обновляет lastAccess (LRU touch);
  /// запись о пропавшем с диска файле удаляется.
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async {
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) return null;
    final row = await store.cacheEntry(key);
    if (row == null) return null;
    final size = await _length(row.localPath);
    if (size == 0) {
      await store.deleteCacheEntry(key);
      return null;
    }
    if (!row.complete) return null;
    await store.touchCacheEntry(key, size);
    return _toEntry(row, size, await _remoteFilenameOf(row));
  }

  /// Все завершённые записи с файлом на диске, LRU-порядок.
  Future<List<SoulseekCacheEntry>> getAllCacheEntries() async {
    final out = <SoulseekCacheEntry>[];
    for (final row in await store.cacheEntriesLru()) {
      if (!row.complete) continue;
      final size = await _length(row.localPath);
      if (size == 0) continue;
      out.add(_toEntry(row, size, await _remoteFilenameOf(row)));
    }
    return out;
  }

  /// Дописывает метаданные записи, у которой их нет (файл докачан без
  /// title — prefetch и т.п.). Существующий title не перезаписывается.
  Future<void> fillMissingMetadata(
    String cacheKey, {
    String? title,
    String? artist,
    int? durationSeconds,
  }) async {
    if (title == null || title.trim().isEmpty) return;
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) return;
    final row = await store.cacheEntry(key);
    if (row == null || (row.title?.trim().isNotEmpty ?? false)) return;
    await store.upsertCacheEntry(row.copyWith(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    ));
  }

  /// Исходный путь файла у пира: название записи без title (сам файл
  /// назван хэшем cacheKey) и запрос обложки.
  Future<String?> _remoteFilenameOf(SoulseekCacheRow row) async {
    try {
      return await store.remoteFilenameFor(row.cacheKey);
    } on Object {
      return null;
    }
  }

  /// Публикует проверенный мостом `.part` как файл кэша и регистрирует его.
  /// Возвращает итоговый путь.
  Future<String> publish({
    required String cacheKey,
    required String extension,
    required String partPath,
    String? title,
    String? artist,
    int? durationSeconds,
  }) async {
    final key = _requireKey(cacheKey);
    final ext = sanitizeExtension(extension) ?? 'dat';
    final dest = p.join(cacheDir, '$key.$ext');
    await Directory(cacheDir).create(recursive: true);

    // Прокси дочитывает `.part` до конца и закрывает его; ждём, но не вечно —
    // поставленный на паузу плеер может держать соединение открытым.
    await FileReadLeases.whenIdle(partPath)
        .timeout(publishWait, onTimeout: () {});

    cancelPendingDelete(dest);
    final destFile = File(dest);
    if (await destFile.exists()) await destFile.delete();
    try {
      await File(partPath).rename(dest);
    } on FileSystemException {
      // `.part` ещё открыт читателем: публикуем копию, остаток удалится,
      // когда читатель закроет файл.
      await File(partPath).copy(dest);
      deleteWhenIdle(partPath);
    }

    final now = DateTime.now();
    await store.upsertCacheEntry(SoulseekCacheRow(
      cacheKey: key,
      localPath: dest,
      sizeBytes: await _length(dest),
      complete: true,
      lastAccessAt: now,
      cachedAt: now,
      extension: ext,
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    ));
    await cleanup();
    return dest;
  }

  /// Удаляет файл кэша, остаток `.part` и записи трансферов для [cacheKey].
  Future<bool> removeCache(String cacheKey) async {
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) return false;
    var removed = false;
    final row = await store.cacheEntry(key);
    if (row != null) {
      removed = await _tryDelete(row.localPath);
      if (removed || !await File(row.localPath).exists()) {
        await store.deleteCacheEntry(key);
      } else {
        // Файл открыт (играет): на Windows его не удалить. Запись остаётся,
        // пока файл не удалится, — иначе он стал бы сиротой вне LRU-лимита.
        _deleteWhenIdle(row.localPath, then: () => store.deleteCacheEntry(key));
      }
    }
    removed = await _tryDelete(p.join(incompleteDir, '$key.part')) || removed;
    await store.deleteTransfersByCacheKey(key);
    return removed;
  }

  Future<void> pin(String cacheKey, {required bool pinned}) async {
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) return;
    await store.setCachePinned(key, pinned);
  }

  /// Новый лимит (0 — без лимита); при снижении сразу вытесняет LRU.
  Future<void> updateMaxCacheSizeBytes(int bytes) async {
    _maxCacheSizeBytes = bytes;
    if (bytes > 0) await cleanup();
  }

  /// LRU-вытеснение незакреплённых файлов до лимита. Возвращает число
  /// удалённых файлов.
  Future<int> cleanup() async {
    if (_maxCacheSizeBytes <= 0) return 0;
    final rows = await store.cacheEntriesLru();
    var total = rows
        .where((r) => r.complete)
        .fold<int>(0, (sum, r) => sum + r.sizeBytes);
    if (total <= _maxCacheSizeBytes) return 0;
    var removed = 0;
    for (final row in rows) {
      if (total <= _maxCacheSizeBytes) break;
      if (!row.complete || row.pinned) continue;
      final size = await _length(row.localPath);
      if (await _tryDelete(row.localPath)) {
        await store.deleteCacheEntry(row.cacheKey);
        await store.deleteTransfersByCacheKey(row.cacheKey);
        total -= size;
        removed++;
      }
    }
    return removed;
  }

  /// Удаляет [path], когда его закроют читатели (на Windows открытый файл
  /// не удалить). Ошибки глотаются: остаток перезапишет следующая загрузка.
  void deleteWhenIdle(String path) => _deleteWhenIdle(path);

  /// Отменяет отложенное удаление [path] (файл снова нужен новой загрузке).
  void cancelPendingDelete(String path) => _pendingDeletes.remove(path);

  void _deleteWhenIdle(String path, {Future<void> Function()? then}) {
    final seq = ++_deleteSeq;
    _pendingDeletes[path] = seq;
    unawaited(() async {
      await FileReadLeases.whenIdle(path);
      if (_pendingDeletes[path] != seq) return;
      _pendingDeletes.remove(path);
      if (await _tryDelete(path) && then != null) await then();
    }());
  }

  /// Ключ — простое имя файла: без сепараторов и traversal.
  static String? sanitizeCacheKey(String cacheKey) {
    if (cacheKey.trim().isEmpty) return null;
    if (cacheKey.contains('..') ||
        cacheKey.contains('/') ||
        cacheKey.contains(r'\')) {
      return null;
    }
    final cleaned = _replaceInvalid(cacheKey);
    return cleaned.trim().isEmpty ? null : cleaned;
  }

  static String? sanitizeExtension(String extension) {
    var ext = extension.trim();
    while (ext.startsWith('.')) {
      ext = ext.substring(1);
    }
    if (ext.isEmpty ||
        ext.contains('..') ||
        ext.contains('/') ||
        ext.contains(r'\')) {
      return null;
    }
    return _replaceInvalid(ext);
  }

  static String _replaceInvalid(String s) => String.fromCharCodes(s.codeUnits
      .map((c) => c < 32 || '<>:"|?*'.codeUnits.contains(c) ? 0x5F : c));

  String _requireKey(String cacheKey) {
    final key = sanitizeCacheKey(cacheKey);
    if (key == null) {
      throw const SoulseekException(
          'INVALID_CACHE_KEY', 'cacheKey contains invalid characters');
    }
    return key;
  }

  static SoulseekCacheEntry _toEntry(
    SoulseekCacheRow row,
    int size, [
    String? remoteFilename,
  ]) =>
      SoulseekCacheEntry(
        cacheKey: row.cacheKey,
        localPath: row.localPath,
        sizeBytes: size,
        complete: true,
        pinned: row.pinned,
        title: row.title,
        artist: row.artist,
        durationSeconds: row.durationSeconds,
        extension: row.extension,
        cachedAt: row.cachedAt,
        remoteFilename: remoteFilename,
      );

  static Future<int> _length(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return 0;
    }
  }

  static Future<bool> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      await file.delete();
      return true;
    } on FileSystemException catch (e) {
      debugPrint('[Soulseek] delete failed $path: ${e.message}');
      return false;
    }
  }
}
