import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'history_repository.dart';

/// Единая база данных приложения (SQLite).
///
/// Хранит **все** данные, которые раньше лежали в SharedPreferences:
/// плейлисты, историю прослушивания, историю поиска, настройки, кэш обложек
/// плейлистов и т.д.
///
/// ## Восстановление после переустановки
///
/// База создаётся в `getApplicationDocumentsDirectory()` — стандартном
/// каталоге документов приложения. На Android этот каталог автоматически
/// попадает в системный авто-бэкап (Android 6+) через `<include>` правил
/// в `backup_rules.xml`. На iOS каталог `Documents/` по умолчанию
/// бэкапится iCloud.
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
/// Миграции версионируются стандартным `onUpgrade` sqflite.
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _dbName = 'player_data.db';
  static const int _dbVersion = 2;

  Database? _db;

  /// Путь, по которому лежит (или будет создан) файл базы.
  ///
  /// Используется `getApplicationDocumentsDirectory()` — стандартный каталог
  /// документов приложения. На Android этот каталог автоматически попадает
  /// в системный авто-бэкап (Android 6+), на iOS — бэкапится iCloud.
  Future<String> get _dbPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _dbName);
  }

  /// Гарантирует, что база открыта и готова к использованию.
  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = await _dbPath;
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('[AppDatabase] DB upgraded: $oldVersion -> $newVersion');
    // v1 → v2: структура БД не изменилась, просто поменялся путь к файлу.
    // При первом запуске после обновления sqflite создаст новую БД
    // (старая лежала в external storage, который удалён).
    // Данные восстановятся из системного авто-бэкапа Android или
    // из ручного полного бэкапа пользователя.
  }

  Future<void> _onCreate(Database db, int version) async {
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

  /// Закрыть БД (например, при остановке приложения).
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Путь к файлу базы на диске — для отладки и бэкапа вручную.
  Future<String> get databaseFilePath => _dbPath;

  /// Возвращает `true`, если приложение запущено с пустой БД
  /// (нет плейлистов, нет истории, нет настроек — чистая миграция
  /// или свежая установка).
  ///
  /// Используется для автоматического предложения восстановления
  /// из полного бэкапа при первом запуске.
  Future<bool> isEmptyForImport() async {
    final db = await database;
    final playlistCount = (await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM playlists',
    )).first['cnt'] as int;
    final historyCount = (await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM listen_history',
    )).first['cnt'] as int;
    final settingsCount = (await db.rawQuery(
      "SELECT COUNT(*) AS cnt FROM settings WHERE key NOT LIKE 'migration\\_%' ESCAPE '\\'",
    )).first['cnt'] as int;

    return playlistCount == 0 && historyCount == 0 && settingsCount == 0;
  }

  // ==============================================================
  //  MIGRATION из SharedPreferences
  // ==============================================================

  /// Переносит данные из SharedPreferences в SQLite.
  ///
  /// Двухфазная миграция:
  /// - v1: настройки + история поиска (ключи корректны)
  /// - v2: плейлисты + история прослушивания (исправленные ключи)
  ///
  /// Каждая фаза идемпотентна и проверяет свой флаг в таблице `settings`.
  /// Возвращает `true`, если была выполнена хотя бы одна фаза миграции.
  Future<bool> migrateFromSharedPreferences({
    required String playlistsJson,
    required String listenHistoryJson,
    required int historyLimit,
    required List<String> searchHistory,
    required Map<String, String> allSettings,
  }) async {
    final db = await database;

    // Фаза 1: настройки + поиск (v1)
    final v1Done = await db.rawQuery(
      'SELECT value FROM settings WHERE key = ?',
      ['migration_v1_done'],
    );
    final needV1 = v1Done.isEmpty || v1Done.first['value'] != '1';

    // Фаза 2: плейлисты + история (v2, исправленные ключи)
    final v2Done = await db.rawQuery(
      'SELECT value FROM settings WHERE key = ?',
      ['migration_v2_fixed'],
    );
    final needV2 = v2Done.isEmpty || v2Done.first['value'] != '1';

    if (!needV1 && !needV2) return false;

    // Фаза 1: настройки + поиск (v1) — только если ещё не выполнена
    if (needV1) {
      await db.transaction((txn) async {
        // --- Настройки ---
        for (final entry in allSettings.entries) {
          if (entry.key.startsWith('flutter.')) continue;
          await txn.insert(
            'settings',
            {'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await txn.insert(
          'settings',
          {'key': 'history_limit_v1', 'value': historyLimit.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        // --- История поиска ---
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        int sOrder = 0;
        for (final query in searchHistory) {
          await txn.insert(
            'search_history',
            {
              'query': query,
              'searched_at_ms': nowMs - sOrder * 1000,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          sOrder++;
        }

        await txn.insert(
          'settings',
          {'key': 'migration_v1_done', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    }

    // Фаза 2: плейлисты + история (v2, исправленные ключи)
    // Используем INSERT OR IGNORE, чтобы не затереть уже созданные
    // пользователем плейлисты/историю после обновления.
    if (needV2) {
      await db.transaction((txn) async {
        // --- Плейлисты ---
        if (playlistsJson.isNotEmpty) {
          try {
            final arr = (jsonDecode(playlistsJson) as List)
                .cast<Map<String, dynamic>>();
            int pOrder = 0;
            for (final pJson in arr) {
              final playlist = Playlist.fromJson(pJson);
              // IGNORE: не перезаписываем уже существующие плейлисты
              final inserted = await txn.rawInsert(
                'INSERT OR IGNORE INTO playlists '
                '(id, name, created_at_ms, sort_order) '
                'VALUES (?, ?, ?, ?)',
                [
                  playlist.id,
                  playlist.name,
                  playlist.createdAt.millisecondsSinceEpoch,
                  pOrder++,
                ],
              );
              if (inserted > 0) {
                // Вставляем треки и обложку только для нового плейлиста
                if (playlist.coverCustomUrl != null) {
                  await txn.insert(
                    'playlist_covers',
                    {
                      'playlist_id': playlist.id,
                      'cover_url': playlist.coverCustomUrl,
                    },
                    conflictAlgorithm: ConflictAlgorithm.replace,
                  );
                }
                int tOrder = 0;
                for (final track in playlist.tracks) {
                  await txn.insert('playlist_tracks', {
                    'playlist_id': playlist.id,
                    'track_global_id': track.globalId,
                    'source_id': track.sourceId,
                    'track_id': track.id,
                    'title': track.title,
                    'artist': track.artist,
                    'duration_ms': track.duration?.inMilliseconds,
                    'artwork_url': track.artworkUrl,
                    'extra_json':
                        jsonEncode(extraPrimitives(track.extra)),
                    'quality_score': track.qualityScore,
                    'quality_label': track.qualityLabel,
                    'sort_order': tOrder++,
                  });
                }
              }
            }
          } catch (_) {
            // Битый JSON — ок.
          }
        }

        // --- История прослушивания ---
        if (listenHistoryJson.isNotEmpty) {
          try {
            final arr = (jsonDecode(listenHistoryJson) as List)
                .cast<Map<String, dynamic>>();
            for (final entry in arr) {
              final trackMap =
                  (entry['track'] as Map).cast<String, dynamic>();
              final track = Track.fromMap(trackMap);
              await txn.rawInsert(
                'INSERT OR IGNORE INTO listen_history '
                '(track_global_id, source_id, track_id, title, artist, '
                'duration_ms, artwork_url, extra_json, quality_score, '
                'quality_label, played_at_ms) '
                'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                [
                  track.globalId,
                  track.sourceId,
                  track.id,
                  track.title,
                  track.artist,
                  track.duration?.inMilliseconds,
                  track.artworkUrl,
                  jsonEncode(extraPrimitives(track.extra)),
                  track.qualityScore,
                  track.qualityLabel,
                  entry['played_at'] as int,
                ],
              );
            }
          } catch (_) {
            // Игнорируем битую историю.
          }
        }

        await txn.insert(
          'settings',
          {'key': 'migration_v2_fixed', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    }

    return true;
  }

  /// Рекурсивно обходит [extra] и заменяет все значения на JSON-совместимые
  /// примитивы (String/num/bool/null) либо их вложенные коллекции.
  static Map<String, dynamic> extraPrimitives(Map<String, dynamic> extra) {
    return extra.map((k, v) => MapEntry(k, _toPrimitive(v)));
  }

  static dynamic _toPrimitive(dynamic v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _toPrimitive(val)));
    }
    if (v is List) {
      return v.map((e) => _toPrimitive(e)).toList();
    }
    return v.toString();
  }

  // ==============================================================
  //  PLAYLISTS
  // ==============================================================

  /// Загружает все плейлисты (с треками и кастомными обложками) из БД,
  /// сортируя их «новые сверху».
  Future<List<Playlist>> loadPlaylists() async {
    final db = await database;
    final rows = await db.query('playlists', orderBy: 'created_at_ms DESC');
    final result = <Playlist>[];
    for (final row in rows) {
      final tracks = await db.query(
        'playlist_tracks',
        where: 'playlist_id = ?',
        whereArgs: [row['id']],
        orderBy: 'sort_order ASC',
      );
      final coverRows = await db.query(
        'playlist_covers',
        where: 'playlist_id = ?',
        whereArgs: [row['id']],
        limit: 1,
      );
      final coverUrl =
          coverRows.isNotEmpty ? coverRows.first['cover_url'] as String? : null;

      result.add(Playlist(
        id: row['id'] as String,
        name: row['name'] as String,
        tracks: tracks.map(_trackFromRow).toList(),
        coverCustomUrl: coverUrl,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at_ms'] as num).toInt()),
      ));
    }
    return result;
  }

  Track _trackFromRow(Map<String, dynamic> row) {
    Map<String, dynamic> extra = const {};
    if (row['extra_json'] != null &&
        (row['extra_json'] as String).isNotEmpty) {
      try {
        extra = (jsonDecode(row['extra_json'] as String) as Map)
            .cast<String, dynamic>();
      } catch (_) {}
    }
    return Track(
      id: row['track_id'] as String,
      sourceId: row['source_id'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String,
      duration: row['duration_ms'] != null
          ? Duration(milliseconds: (row['duration_ms'] as num).toInt())
          : null,
      artworkUrl: row['artwork_url'] as String?,
      qualityScore: row['quality_score'] as int?,
      qualityLabel: row['quality_label'] as String?,
      extra: extra,
    );
  }

  /// Сохраняет (INSERT или REPLACE) плейлист и все его треки.
  Future<void> savePlaylist(Playlist playlist, int sortOrder) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'playlists',
        {
          'id': playlist.id,
          'name': playlist.name,
          'created_at_ms': playlist.createdAt.millisecondsSinceEpoch,
          'sort_order': sortOrder,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'playlist_tracks',
        where: 'playlist_id = ?',
        whereArgs: [playlist.id],
      );

      int tOrder = 0;
      for (final track in playlist.tracks) {
        await txn.insert('playlist_tracks', {
          'playlist_id': playlist.id,
          'track_global_id': track.globalId,
          'source_id': track.sourceId,
          'track_id': track.id,
          'title': track.title,
          'artist': track.artist,
          'duration_ms': track.duration?.inMilliseconds,
          'artwork_url': track.artworkUrl,
            'extra_json': jsonEncode(extraPrimitives(track.extra)),
            'quality_score': track.qualityScore,
            'quality_label': track.qualityLabel,
            'sort_order': tOrder++,
          });
      }

      await txn.delete(
        'playlist_covers',
        where: 'playlist_id = ?',
        whereArgs: [playlist.id],
      );
      if (playlist.coverCustomUrl != null) {
        await txn.insert('playlist_covers', {
          'playlist_id': playlist.id,
          'cover_url': playlist.coverCustomUrl,
        });
      }
    });
  }

  /// Сохраняет все плейлисты разом (полный flush).
  Future<void> saveAllPlaylists(List<Playlist> playlists) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks');
      await txn.delete('playlist_covers');
      await txn.delete('playlists');

      for (var i = 0; i < playlists.length; i++) {
        final playlist = playlists[i];
        await txn.insert('playlists', {
          'id': playlist.id,
          'name': playlist.name,
          'created_at_ms': playlist.createdAt.millisecondsSinceEpoch,
          'sort_order': i,
        });

        if (playlist.coverCustomUrl != null) {
          await txn.insert('playlist_covers', {
            'playlist_id': playlist.id,
            'cover_url': playlist.coverCustomUrl,
          });
        }

        for (var j = 0; j < playlist.tracks.length; j++) {
          final track = playlist.tracks[j];
          await txn.insert('playlist_tracks', {
            'playlist_id': playlist.id,
            'track_global_id': track.globalId,
            'source_id': track.sourceId,
            'track_id': track.id,
            'title': track.title,
            'artist': track.artist,
            'duration_ms': track.duration?.inMilliseconds,
            'artwork_url': track.artworkUrl,
            'extra_json': jsonEncode(extraPrimitives(track.extra)),
            'quality_score': track.qualityScore,
            'quality_label': track.qualityLabel,
            'sort_order': j,
          });
        }
      }
    });
  }

  /// Удаляет плейлист из БД.
  Future<void> deletePlaylist(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('playlist_covers',
          where: 'playlist_id = ?', whereArgs: [id]);
      await txn.delete('playlist_tracks',
          where: 'playlist_id = ?', whereArgs: [id]);
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Полная очистка таблиц плейлистов (для тестов).
  @visibleForTesting
  Future<void> clearPlaylists() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks');
      await txn.delete('playlist_covers');
      await txn.delete('playlists');
    });
  }

  // ==============================================================
  //  LISTEN HISTORY
  // ==============================================================

  /// Возвращает историю прослушивания, новые сверху, с учётом лимита.
  Future<List<HistoryEntry>> loadListenHistory(int limit) async {
    final db = await database;
    final rows = await db.query(
      'listen_history',
      orderBy: 'played_at_ms DESC',
      limit: limit,
    );
    return rows.map((row) {
      final track = _trackFromRow(row);
      return HistoryEntry(
        track: track,
        playedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['played_at_ms'] as num).toInt()),
      );
    }).toList();
  }

  /// Добавляет запись в историю (одну).
  ///
  /// Операция атомарна: DELETE + INSERT выполняются в одной транзакции,
  /// чтобы при падении INSERT старая запись не была потеряна.
  Future<void> addListenHistoryEntry(HistoryEntry entry) async {
    final db = await database;
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
        'extra_json': jsonEncode(extraPrimitives(entry.track.extra)),
        'quality_score': entry.track.qualityScore,
        'quality_label': entry.track.qualityLabel,
        'played_at_ms': entry.playedAt.millisecondsSinceEpoch,
      });
    });
  }

  /// Удаляет конкретную запись из истории.
  Future<void> removeListenHistoryEntry(HistoryEntry entry) async {
    final db = await database;
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
  Future<void> clearListenHistory() async {
    final db = await database;
    await db.delete('listen_history');
  }

  /// Подрезает историю до лимита (удаляет старые записи).
  Future<void> trimListenHistory(int limit) async {
    final db = await database;
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

  // ==============================================================
  //  SEARCH HISTORY
  // ==============================================================

  /// Возвращает историю поиска, новые сверху, не более [limit].
  Future<List<String>> getSearchHistory(int limit) async {
    final db = await database;
    final rows = await db.query(
      'search_history',
      columns: ['query'],
      orderBy: 'searched_at_ms DESC',
      limit: limit,
    );
    return rows.map((r) => r['query'] as String).toList();
  }

  /// Записывает историю поиска целиком (с дедупликацией и лимитом).
  Future<void> setSearchHistory(List<String> queries, int limit) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('search_history');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < queries.length && i < limit; i++) {
        await txn.insert('search_history', {
          'query': queries[i],
          'searched_at_ms': now - i * 1000,
        });
      }
    });
  }

  /// Добавляет поисковый запрос.
  Future<void> addSearchQuery(String query) async {
    final db = await database;
    await db.delete(
      'search_history',
      where: 'LOWER(query) = LOWER(?)',
      whereArgs: [query],
    );
    await db.insert('search_history', {
      'query': query,
      'searched_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Удаляет конкретный поисковый запрос.
  Future<void> removeSearchQuery(String query) async {
    final db = await database;
    await db.delete('search_history', where: 'query = ?', whereArgs: [query]);
  }

  /// Очищает всю историю поиска.
  Future<void> clearSearchHistory() async {
    final db = await database;
    await db.delete('search_history');
  }

  /// Подрезает историю поиска до лимита.
  Future<void> trimSearchHistory(int limit) async {
    final db = await database;
    final rows = await db.query(
      'search_history',
      columns: ['searched_at_ms'],
      orderBy: 'searched_at_ms DESC',
      limit: limit,
    );
    if (rows.length >= limit) {
      final cutoff = rows.last['searched_at_ms'] as int;
      await db.delete(
        'search_history',
        where: 'searched_at_ms < ?',
        whereArgs: [cutoff],
      );
    }
  }

  // ==============================================================
  //  SETTINGS
  // ==============================================================

  /// Читает значение настройки.
  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['value'] as String? : null;
  }

  /// Записывает значение настройки.
  Future<void> setSetting(String key, String value) async {
    final db = await database;
    try {
      await db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e, st) {
      debugPrint('[AppDatabase] Failed to persist setting $key: $e\n$st');
    }
  }

  /// Удаляет настройку.
  Future<void> removeSetting(String key) async {
    final db = await database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Возвращает все настройки в виде мапы.
  Future<Map<String, String>> getAllSettings() async {
    final db = await database;
    final rows = await db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  // ==============================================================
  //  PLAYBACK STATE (save / restore session)
  // ==============================================================

  /// Сохраняет текущую очередь и индекс в `playback_state`.
  /// Вызывается из [PlayerService] при каждом изменении очереди.
  Future<void> savePlaybackSession({
    required List<Map<String, dynamic>> queueRows,
    required int currentIndex,
    required int positionMs,
  }) async {
    final db = await database;
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
      loadPlaybackSession() async {
    final db = await database;
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
      return _trackFromRow(r);
    }).toList();

    if (queue.isEmpty) return null;

    return (
      queue: queue,
      currentIndex: (row['current_index'] as int?) ?? -1,
      positionMs: (row['position_ms'] as int?) ?? 0,
    );
  }

  // ==============================================================
  //  FULL BACKUP / RESTORE
  // ==============================================================

  /// Экспортирует всю БД в JSON-строку (полный бэкап).
  Future<String> exportFullBackup() async {
    final db = await database;
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
  Future<void> importFullBackup(String raw) async {
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

    final db = await database;
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