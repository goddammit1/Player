import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/track.dart';

/// DAO состояния плеера: операции над таблицей `playback_state`
/// (сохранение/восстановление сессии воспроизведения).
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
class PlaybackDao {
  PlaybackDao._();
  static final PlaybackDao instance = PlaybackDao._();

  /// Сохраняет текущую очередь и индекс в `playback_state`.
  /// Вызывается из [PlayerService] при каждом изменении очереди.
  Future<void> savePlaybackSession(
      Database db,
      {
      required List<Map<String, dynamic>> queueRows,
      required int currentIndex,
      required int positionMs,
    }) async {
    final json = jsonEncode(queueRows);
    await db.update(
      'playback_state',
      {
        'queue_json': json,
        'current_index': currentIndex,
        'position_ms': positionMs,
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = 1',
    );
  }

  /// Загружает сохранённое состояние плеера.
  ///
  /// Возвращает `null`, если очередь пуста (ничего не восстанавливаем).
  Future<({List<Track> queue, int currentIndex, int positionMs})?>
      loadPlaybackSession(Database db) async {
    final rows = await db.query('playback_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;

    final row = rows.first;
    final json = row['queue_json'] as String;
    if (json.isEmpty || json == '[]') return null;

    final List raw;
    try {
      raw = jsonDecode(json) as List;
    } catch (_) {
      return null;
    }

    // SESSION-01: разбор per-entry — одна битая запись не должна ронять
    // восстановление всей очереди.
    final queue = <Track>[];
    var skipped = 0;
    var skippedBeforeCurrent = 0;
    final savedIndex = (row['current_index'] as int?) ?? -1;

    for (final entry in raw) {
      final indexBefore = queue.length + skipped;
      try {
        if (entry is! Map) {
          throw const FormatException('queue entry is not a Map');
        }
        final track = Track.fromMap(entry.cast<String, dynamic>());
        if (track.id.isEmpty) {
          throw const FormatException('queue entry has empty id');
        }
        queue.add(track);
      } catch (e) {
        skipped++;
        if (savedIndex >= 0 && indexBefore < savedIndex) {
          skippedBeforeCurrent++;
        }
        if (kDebugMode) {
          debugPrint('[PlaybackDao] skipping broken queue entry '
              '#$indexBefore: $e');
        }
      }
    }

    if (queue.isEmpty) return null;

    return (
      queue: queue,
      // Если до сохранённого индекса были пропущены записи — смещаем его,
      // чтобы текущий трек остался тем же (выше вызывающий код clamp-ит).
      currentIndex: savedIndex - skippedBeforeCurrent,
      positionMs: (row['position_ms'] as int?) ?? 0,
    );
  }
}