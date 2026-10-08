import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../models/track.dart';
import 'track_row_codec.dart';

/// Запись индекса аудио-кэша: трек и момент первого кэширования.
class AudioCacheIndexEntry {
  const AudioCacheIndexEntry({
    required this.cacheId,
    required this.track,
    required this.cachedAt,
  });

  final String cacheId;
  final Track track;
  final DateTime cachedAt;
}

/// DAO таблицы `audio_cache_index`: метаданные треков, лежащих в
/// дисковом аудио-кэше (`YoutubeCache`). Источник истины о наличии трека
/// в кэше — файл на диске; индекс лишь даёт ему название и дату.
class AudioCacheIndexDao {
  AudioCacheIndexDao._();
  static final AudioCacheIndexDao instance = AudioCacheIndexDao._();

  static const String _table = 'audio_cache_index';

  /// Добавляет или обновляет запись. Метаданные перезаписываются (могли
  /// обогатиться, например обложкой), дата первого кэширования сохраняется,
  /// если не задан [resetCachedAt] (новая загрузка файла).
  Future<void> upsert(
    Database db,
    String cacheId,
    Track track, {
    DateTime? cachedAt,
    bool resetCachedAt = false,
  }) async {
    final cachedAtMs = (cachedAt ?? DateTime.now()).millisecondsSinceEpoch;
    final values = <String, Object?>{
      'source_id': track.sourceId,
      'track_id': track.id,
      'title': track.title,
      'artist': track.artist,
      'duration_ms': track.duration?.inMilliseconds,
      'artwork_url': track.artworkUrl,
      'extra_json': jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
      'quality_score': track.qualityScore,
      'quality_label': track.qualityLabel,
      if (resetCachedAt) 'cached_at_ms': cachedAtMs,
    };
    await db.transaction((txn) async {
      final updated = await txn.update(
        _table,
        values,
        where: 'cache_id = ?',
        whereArgs: [cacheId],
      );
      if (updated > 0) return;
      await txn.insert(_table, {
        ...values,
        'cache_id': cacheId,
        'cached_at_ms': cachedAtMs,
      });
    });
  }

  /// Все записи индекса, ключ — cache id.
  Future<Map<String, AudioCacheIndexEntry>> getAll(Database db) async {
    final rows = await db.query(_table);
    final result = <String, AudioCacheIndexEntry>{};
    for (final row in rows) {
      final cacheId = row['cache_id'] as String;
      result[cacheId] = AudioCacheIndexEntry(
        cacheId: cacheId,
        track: TrackRowCodec.fromRow(row),
        cachedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['cached_at_ms'] as num).toInt(),
        ),
      );
    }
    return result;
  }

  /// Удаляет записи по списку cache id.
  Future<void> removeAll(Database db, Iterable<String> cacheIds) async {
    final ids = cacheIds.toList(growable: false);
    if (ids.isEmpty) return;
    final batch = db.batch();
    for (final id in ids) {
      batch.delete(_table, where: 'cache_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Очищает индекс, кроме [keep] (файл играющего трека не удаляется).
  Future<void> clear(Database db, {String? keep}) async {
    if (keep == null) {
      await db.delete(_table);
    } else {
      await db.delete(_table, where: 'cache_id != ?', whereArgs: [keep]);
    }
  }
}
