import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// DAO полного бэкапа/восстановления БД.
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
/// ВАЖНО: формат бэкапа (ключи `format`, `version`, набор таблиц) — вне правок.
class BackupDao {
  BackupDao._();
  static final BackupDao instance = BackupDao._();

  /// Экспортирует всю БД в JSON-строку (полный бэкап).
  Future<String> exportFullBackup(Database db) async {
    final playlists =
        await db.query('playlists', orderBy: 'sort_order ASC');
    final playlistTracks =
        await db.query('playlist_tracks', orderBy: 'sort_order ASC');
    final playlistCovers = await db.query('playlist_covers');
    final history =
        await db.query('listen_history', orderBy: 'played_at_ms DESC');
    final search =
        await db.query('search_history', orderBy: 'searched_at_ms DESC');
    final settings = await db.query('settings');
    final playbackState =
        await db.query('playback_state', where: 'id = 1', limit: 1);

    final map = <String, dynamic>{
      'format': 'player_full_backup',
      'version': 2,
      'exported_at_ms': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists,
      'playlist_tracks': playlistTracks,
      'playlist_covers': playlistCovers,
      'listen_history': history,
      'search_history': search,
      'settings': settings,
      'playback_state': playbackState,
    };
    return const JsonEncoder().convert(map);
  }

  /// Импортирует полный бэкап из JSON-строки.
  /// Замещает все текущие данные. Бросает [FormatException] при ошибке.
  Future<void> importFullBackup(Database db, String raw) async {
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Not a valid JSON file');
    }
    if (parsed is! Map) {
      throw const FormatException('Unexpected JSON structure');
    }
    final format = parsed['format'];
    if (format != 'player_full_backup') {
      throw const FormatException('Not a full backup file');
    }
    final version = parsed['version'];
    if (version != 1 && version != 2) {
      throw FormatException('Unsupported backup version: $version');
    }

    await db.transaction((txn) async {
      // Очищаем все таблицы в правильном порядке (сначала дочерние)
      await txn.delete('playlist_tracks');
      await txn.delete('playlist_covers');
      await txn.delete('playlists');
      await txn.delete('listen_history');
      await txn.delete('search_history');
      await txn.delete('settings');

      // Восстанавливаем в правильном порядке (сначала родительские)
      for (final row in (parsed['playlists'] as List?) ?? []) {
        await txn.insert('playlists', (row as Map).cast<String, dynamic>());
      }
      for (final row in (parsed['playlist_tracks'] as List?) ?? []) {
        await txn.insert(
            'playlist_tracks', (row as Map).cast<String, dynamic>());
      }
      for (final row in (parsed['playlist_covers'] as List?) ?? []) {
        await txn.insert(
            'playlist_covers', (row as Map).cast<String, dynamic>());
      }
      for (final row in (parsed['listen_history'] as List?) ?? []) {
        await txn.insert(
            'listen_history', (row as Map).cast<String, dynamic>());
      }
      for (final row in (parsed['search_history'] as List?) ?? []) {
        await txn.insert(
            'search_history', (row as Map).cast<String, dynamic>());
      }
      for (final row in (parsed['settings'] as List?) ?? []) {
        await txn.insert('settings', (row as Map).cast<String, dynamic>());
      }

      // playback_state (v2+)
      if (version >= 2) {
        final psRows = (parsed['playback_state'] as List?) ?? [];
        if (psRows.isNotEmpty) {
          // Удаляем текущую строку playback_state и вставляем из бэкапа
          await txn.delete('playback_state');
          for (final row in psRows) {
            await txn.insert(
                'playback_state', (row as Map).cast<String, dynamic>());
          }
        }
      }
    });
  }
}