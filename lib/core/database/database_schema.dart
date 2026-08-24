import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Схема SQLite-базы приложения и версионируемые миграции.
///
/// Выделено из монолита [AppDatabase], чтобы отделить обязанность
/// «определение таблиц / миграции» от слоя доступа к данным (DAO).
///
/// ## Таблицы
///
/// | Таблица             | Назначение                        |
/// |---------------------|-----------------------------------|
/// | `playlists`         | Плейлисты (один на строку)       |
/// | `playlist_tracks`   | Треки внутри плейлистов           |
/// | `listen_history`    | История прослушивания             |
/// | `search_history`    | История поисковых запросов        |
/// | `settings`          | Все настройки (key-value)         |
/// | `playlist_covers`   | Пути к кастомным обложкам         |
/// | `playback_state`    | Сохранённая очередь плеера        |
///
/// ВАЖНО: схема и порядок миграций — вне правок. Данный класс только
/// переносит существующий код из `AppDatabase` без изменения поведения.
abstract class AppDatabaseSchema {
  static const String dbName = 'player_data.db';
  static const int dbVersion = 4;

  /// Создает все таблицы (вызывается sqflite при создании нового файла).
  static Future<void> create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        track_global_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        duration_ms INTEGER,
        artwork_url TEXT,
        extra_json TEXT,
        quality_score INTEGER,
        quality_label TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_playlist_tracks_playlist
      ON playlist_tracks(playlist_id, sort_order)
    ''');

    await db.execute('''
      CREATE TABLE listen_history (
        track_global_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        duration_ms INTEGER,
        artwork_url TEXT,
        extra_json TEXT,
        quality_score INTEGER,
        quality_label TEXT,
        played_at_ms INTEGER NOT NULL,
        PRIMARY KEY (track_global_id, played_at_ms)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_listen_history_played
      ON listen_history(played_at_ms DESC)
    ''');

    await db.execute('''
      CREATE TABLE search_history (
        query TEXT PRIMARY KEY,
        searched_at_ms INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_search_history_time
      ON search_history(searched_at_ms DESC)
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_covers (
        playlist_id TEXT PRIMARY KEY REFERENCES playlists(id) ON DELETE CASCADE,
        cover_url TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE playback_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        queue_json TEXT NOT NULL DEFAULT '[]',
        current_index INTEGER NOT NULL DEFAULT -1,
        position_ms INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Всегда ровно одна строка
    await db.rawInsert(
      'INSERT OR IGNORE INTO playback_state (id, queue_json, current_index) '
      'VALUES (1, \'[]\', -1)',
    );
  }

  /// Миграция базы со старой версии на новую (sqflite `onUpgrade`).
  static Future<void> upgrade(
      Database db, int oldVersion, int newVersion) async {
    debugPrint('[AppDatabase] DB upgraded: $oldVersion -> $newVersion');
    if (oldVersion < 3) {
      // v2 → v3: удаляем пустые artwork-кэши, оставшиеся от предыдущих версий.
      // Раньше пустые результаты тоже писались в БД, что блокировало повторный
      // поиск обложек для треков, которые однажды не нашлись.
      try {
        final deleted = await db.delete(
          'settings',
          where: "key LIKE 'artwork_v3_%' AND (value IS NULL OR value = '')",
        );
        if (deleted > 0) {
          debugPrint('[AppDatabase] v3 migration: removed $deleted empty artwork cache entries');
        }
      } catch (_) {}
    }
    if (oldVersion < 4) {
      // v3 → v4: полная очистка artwork-кэша. После фикса iTunes-фильтрации
      // (artist matching) старые записи могут содержать неверные обложки.
      // Удаляем всё, чтобы запустить чистый пересбор кэша.
      try {
        final deleted = await db.delete(
          'settings',
          where: "key LIKE 'artwork_v3_%'",
        );
        if (deleted > 0) {
          debugPrint('[AppDatabase] v4 migration: removed $deleted artwork cache entries (full refresh)');
        }
      } catch (_) {}
    }
  }
}