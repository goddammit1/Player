import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../history_repository.dart';
import 'track_row_codec.dart';

/// DAO истории прослушивания: операции над таблицей `listen_history`.
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
class ListenHistoryDao {
  ListenHistoryDao._();
  static final ListenHistoryDao instance = ListenHistoryDao._();

  /// Возвращает историю прослушивания, новые сверху, с учётом лимита.
  Future<List<HistoryEntry>> loadListenHistory(Database db, int limit) async {
    final rows = await db.query(
      'listen_history',
      orderBy: 'played_at_ms DESC',
      limit: limit,
    );
    return rows.map((row) {
      final track = TrackRowCodec.fromRow(row);
      return HistoryEntry(
        track: track,
        playedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['played_at_ms'] as num).toInt()),
      );
    }).toList();
  }

  /// Добавляет запись в историю (одну) и подрезает её до [limit].
  ///
  /// Операция атомарна: DELETE + INSERT + TRIM выполняются в ОДНОЙ
  /// транзакции, чтобы битых промежуточных состояний не существовало и
  /// не тратились лишние отдельные коммиты (одна запись + trim — один
  /// commit вместо двух).
  Future<void> addListenHistoryEntry(Database db, HistoryEntry entry,
      {int limit = 0}) async {
    await db.transaction((txn) async {
      await txn.delete(
        'listen_history',
        where: 'track_global_id = ?',
        whereArgs: [entry.track.globalId],
      );
      await txn.insert('listen_history', {
        'track_global_id': entry.track.globalId,
        'source_id': entry.track.sourceId,
        'track_id': entry.track.id,
        'title': entry.track.title,
        'artist': entry.track.artist,
        'duration_ms': entry.track.duration?.inMilliseconds,
        'artwork_url': entry.track.artworkUrl,
        'extra_json': jsonEncode(TrackRowCodec.extraPrimitives(entry.track.extra)),
        'quality_score': entry.track.qualityScore,
        'quality_label': entry.track.qualityLabel,
        'played_at_ms': entry.playedAt.millisecondsSinceEpoch,
      });
      if (limit > 0) {
        await _trimInTransaction(txn, limit);
      }
    });
  }

  /// Удаляет лишние записи (старше лимита) внутри уже открытой
  /// транзакции. Один SELECT самых свежих [limit] меток времени + один
  /// DELETE устаревших — без отдельного коммита.
  static Future<void> _trimInTransaction(
      DatabaseExecutor txn, int limit) async {
    final rows = await txn.query(
      'listen_history',
      columns: ['played_at_ms'],
      orderBy: 'played_at_ms DESC',
      limit: limit,
    );
    if (rows.length >= limit) {
      final cutoff = rows.last['played_at_ms'] as int;
      await txn.delete(
        'listen_history',
        where: 'played_at_ms < ?',
        whereArgs: [cutoff],
      );
    }
  }

  /// Удаляет конкретную запись из истории.
  Future<void> removeListenHistoryEntry(Database db, HistoryEntry entry) async {
    await db.delete(
      'listen_history',
      where: 'track_global_id = ? AND played_at_ms = ?',
      whereArgs: [
        entry.track.globalId,
        entry.playedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// Очищает всю историю.
  Future<void> clearListenHistory(Database db) async {
    await db.delete('listen_history');
  }

  /// Обновляет [artworkUrl] во всех записях истории для трека с указанным
  /// [globalId]. Используется после ленивой подгрузки обложки.
  ///
  /// [artworkUrl] может быть null — тогда URL обложки очищается (нужно при
  /// сбросе обложек в истории: `resetAllTrackArtworks`).
  Future<void> updateListenHistoryArtwork(
      Database db, String globalId, String? artworkUrl) async {
    await db.update(
      'listen_history',
      {'artwork_url': artworkUrl},
      where: 'track_global_id = ?',
      whereArgs: [globalId],
    );
  }

  /// Подрезает историю до лимита (удаляет старые записи).
  Future<void> trimListenHistory(Database db, int limit) async {
    final rows = await db.query(
      'listen_history',
      columns: ['played_at_ms'],
      orderBy: 'played_at_ms DESC',
      limit: limit,
    );
    if (rows.length >= limit) {
      final cutoff = rows.last['played_at_ms'] as int;
      await db.delete(
        'listen_history',
        where: 'played_at_ms < ?',
        whereArgs: [cutoff],
      );
    }
  }
}