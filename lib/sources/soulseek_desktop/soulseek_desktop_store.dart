// lib/sources/soulseek_desktop/soulseek_desktop_store.dart
//
// Персист загрузок и кэша Soulseek на Windows. На Android это нативная
// soulseek.db (SoulseekDatabase.kt); здесь — таблицы `soulseek_transfers` и
// `soulseek_cache_entries` в общей AppDatabase (миграция v7).
//
// Интерфейс выделен для тестов: менеджер трансферов работает с
// [MemorySoulseekDesktopStore] (sqflite в виджет-тестах виснет).

import 'package:sqflite/sqflite.dart';

import '../../core/database/app_database.dart';

/// Строка таблицы трансферов.
class SoulseekTransferRow {
  const SoulseekTransferRow({
    required this.downloadId,
    required this.cacheKey,
    required this.peerUsername,
    required this.remoteFilename,
    required this.sizeBytes,
    required this.state,
    this.bytesReceived = 0,
    this.localPath,
    this.fileExtension,
    this.retryCount = 0,
    this.title,
    this.artist,
    this.durationSeconds,
  });

  final String downloadId;
  final String cacheKey;
  final String peerUsername;
  final String remoteFilename;
  final int sizeBytes;

  /// Имя состояния в верхнем регистре (как TransferState в Kotlin).
  final String state;
  final int bytesReceived;
  final String? localPath;
  final String? fileExtension;
  final int retryCount;
  final String? title;
  final String? artist;
  final int? durationSeconds;
}

/// Строка таблицы кэша.
class SoulseekCacheRow {
  const SoulseekCacheRow({
    required this.cacheKey,
    required this.localPath,
    required this.sizeBytes,
    required this.complete,
    required this.lastAccessAt,
    required this.cachedAt,
    this.pinned = false,
    this.extension,
    this.title,
    this.artist,
    this.durationSeconds,
  });

  final String cacheKey;
  final String localPath;
  final int sizeBytes;
  final bool complete;
  final DateTime lastAccessAt;
  final DateTime cachedAt;
  final bool pinned;
  final String? extension;
  final String? title;
  final String? artist;
  final int? durationSeconds;

  SoulseekCacheRow copyWith({
    int? sizeBytes,
    DateTime? lastAccessAt,
    bool? pinned,
  }) =>
      SoulseekCacheRow(
        cacheKey: cacheKey,
        localPath: localPath,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        complete: complete,
        lastAccessAt: lastAccessAt ?? this.lastAccessAt,
        cachedAt: cachedAt,
        pinned: pinned ?? this.pinned,
        extension: extension,
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
      );
}

abstract class SoulseekDesktopStore {
  Future<void> upsertTransfer(SoulseekTransferRow row);

  /// Незавершённые трансферы (не COMPLETED / FAILED / CANCELLED).
  Future<List<SoulseekTransferRow>> unfinishedTransfers();

  Future<void> deleteTransfersByCacheKey(String cacheKey);

  Future<void> upsertCacheEntry(SoulseekCacheRow row);

  Future<SoulseekCacheRow?> cacheEntry(String cacheKey);

  /// Все записи кэша, самые давно использованные — первыми.
  Future<List<SoulseekCacheRow>> cacheEntriesLru();

  Future<void> touchCacheEntry(String cacheKey, int sizeBytes);

  Future<void> setCachePinned(String cacheKey, bool pinned);

  Future<void> deleteCacheEntry(String cacheKey);
}

const _terminalStates = ['COMPLETED', 'FAILED', 'CANCELLED'];

/// Хранилище в памяти (тесты).
class MemorySoulseekDesktopStore implements SoulseekDesktopStore {
  final Map<String, SoulseekTransferRow> transfers = {};
  final Map<String, SoulseekCacheRow> cache = {};

  @override
  Future<void> upsertTransfer(SoulseekTransferRow row) async =>
      transfers[row.downloadId] = row;

  @override
  Future<List<SoulseekTransferRow>> unfinishedTransfers() async => transfers
      .values
      .where((t) => !_terminalStates.contains(t.state))
      .toList();

  @override
  Future<void> deleteTransfersByCacheKey(String cacheKey) async =>
      transfers.removeWhere((_, t) => t.cacheKey == cacheKey);

  @override
  Future<void> upsertCacheEntry(SoulseekCacheRow row) async =>
      cache[row.cacheKey] = row;

  @override
  Future<SoulseekCacheRow?> cacheEntry(String cacheKey) async => cache[cacheKey];

  @override
  Future<List<SoulseekCacheRow>> cacheEntriesLru() async =>
      cache.values.toList()
        ..sort((a, b) => a.lastAccessAt.compareTo(b.lastAccessAt));

  @override
  Future<void> touchCacheEntry(String cacheKey, int sizeBytes) async {
    final row = cache[cacheKey];
    if (row == null) return;
    cache[cacheKey] =
        row.copyWith(sizeBytes: sizeBytes, lastAccessAt: DateTime.now());
  }

  @override
  Future<void> setCachePinned(String cacheKey, bool pinned) async {
    final row = cache[cacheKey];
    if (row == null) return;
    cache[cacheKey] = row.copyWith(pinned: pinned);
  }

  @override
  Future<void> deleteCacheEntry(String cacheKey) async => cache.remove(cacheKey);
}

/// Хранилище в AppDatabase.
class SqliteSoulseekDesktopStore implements SoulseekDesktopStore {
  SqliteSoulseekDesktopStore([AppDatabase? database])
      : _appDb = database ?? AppDatabase.instance;

  final AppDatabase _appDb;

  static const _transfers = 'soulseek_transfers';
  static const _cache = 'soulseek_cache_entries';

  Future<Database> get _db => _appDb.database;

  @override
  Future<void> upsertTransfer(SoulseekTransferRow row) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = <String, Object?>{
      'cache_key': row.cacheKey,
      'peer_username': row.peerUsername,
      'remote_filename': row.remoteFilename,
      'size_bytes': row.sizeBytes,
      'state': row.state,
      'bytes_received': row.bytesReceived,
      'local_path': row.localPath,
      'file_extension': row.fileExtension,
      'retry_count': row.retryCount,
      'title': row.title,
      'artist': row.artist,
      'duration_seconds': row.durationSeconds,
      'updated_at_ms': now,
    };
    final db = await _db;
    await db.transaction((txn) async {
      final updated = await txn.update(_transfers, values,
          where: 'download_id = ?', whereArgs: [row.downloadId]);
      if (updated == 0) {
        await txn.insert(_transfers, {
          ...values,
          'download_id': row.downloadId,
          'created_at_ms': now,
        });
      }
    });
  }

  @override
  Future<List<SoulseekTransferRow>> unfinishedTransfers() async {
    final rows = await (await _db).query(
      _transfers,
      where: 'state NOT IN (?, ?, ?)',
      whereArgs: _terminalStates,
      orderBy: 'created_at_ms',
    );
    return rows.map(_transferFromRow).toList();
  }

  @override
  Future<void> deleteTransfersByCacheKey(String cacheKey) async {
    await (await _db)
        .delete(_transfers, where: 'cache_key = ?', whereArgs: [cacheKey]);
  }

  @override
  Future<void> upsertCacheEntry(SoulseekCacheRow row) async {
    await (await _db).insert(
      _cache,
      {
        'cache_key': row.cacheKey,
        'local_path': row.localPath,
        'size_bytes': row.sizeBytes,
        'extension': row.extension,
        'complete': row.complete ? 1 : 0,
        'last_access_at_ms': row.lastAccessAt.millisecondsSinceEpoch,
        'pinned': row.pinned ? 1 : 0,
        'title': row.title,
        'artist': row.artist,
        'duration_seconds': row.durationSeconds,
        'cached_at_ms': row.cachedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<SoulseekCacheRow?> cacheEntry(String cacheKey) async {
    final rows = await (await _db).query(_cache,
        where: 'cache_key = ?', whereArgs: [cacheKey], limit: 1);
    return rows.isEmpty ? null : _cacheFromRow(rows.first);
  }

  @override
  Future<List<SoulseekCacheRow>> cacheEntriesLru() async {
    final rows =
        await (await _db).query(_cache, orderBy: 'last_access_at_ms ASC');
    return rows.map(_cacheFromRow).toList();
  }

  @override
  Future<void> touchCacheEntry(String cacheKey, int sizeBytes) async {
    await (await _db).update(
      _cache,
      {
        'size_bytes': sizeBytes,
        'last_access_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
    );
  }

  @override
  Future<void> setCachePinned(String cacheKey, bool pinned) async {
    await (await _db).update(_cache, {'pinned': pinned ? 1 : 0},
        where: 'cache_key = ?', whereArgs: [cacheKey]);
  }

  @override
  Future<void> deleteCacheEntry(String cacheKey) async {
    await (await _db)
        .delete(_cache, where: 'cache_key = ?', whereArgs: [cacheKey]);
  }

  static SoulseekTransferRow _transferFromRow(Map<String, Object?> r) =>
      SoulseekTransferRow(
        downloadId: r['download_id']! as String,
        cacheKey: r['cache_key']! as String,
        peerUsername: r['peer_username']! as String,
        remoteFilename: r['remote_filename']! as String,
        sizeBytes: r['size_bytes']! as int,
        state: r['state']! as String,
        bytesReceived: (r['bytes_received'] as int?) ?? 0,
        localPath: r['local_path'] as String?,
        fileExtension: r['file_extension'] as String?,
        retryCount: (r['retry_count'] as int?) ?? 0,
        title: r['title'] as String?,
        artist: r['artist'] as String?,
        durationSeconds: r['duration_seconds'] as int?,
      );

  static SoulseekCacheRow _cacheFromRow(Map<String, Object?> r) =>
      SoulseekCacheRow(
        cacheKey: r['cache_key']! as String,
        localPath: r['local_path']! as String,
        sizeBytes: (r['size_bytes'] as int?) ?? 0,
        complete: r['complete'] == 1,
        lastAccessAt:
            DateTime.fromMillisecondsSinceEpoch(r['last_access_at_ms']! as int),
        cachedAt: DateTime.fromMillisecondsSinceEpoch(r['cached_at_ms']! as int),
        pinned: r['pinned'] == 1,
        extension: r['extension'] as String?,
        title: r['title'] as String?,
        artist: r['artist'] as String?,
        durationSeconds: r['duration_seconds'] as int?,
      );
}
