import 'dart:async';
import 'dart:convert';

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

    final queue = raw.cast<Map<String, dynamic>>().map((r) {
      return Track.fromMap(r);
    }).toList();

    if (queue.isEmpty) return null;

    return (
      queue: queue,
      currentIndex: (row['current_index'] as int?) ?? -1,
      positionMs: (row['position_ms'] as int?) ?? 0,
    );
  }
}