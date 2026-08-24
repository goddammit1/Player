import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'database/backup_dao.dart';
import 'database/database_schema.dart';
import 'database/listen_history_dao.dart';
import 'database/playback_dao.dart';
import 'database/playlist_dao.dart';
import 'database/search_history_dao.dart';
import 'database/settings_dao.dart';
import 'database/track_row_codec.dart';
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
///
/// Класс декомпозирован по обязанностям:
/// - [AppDatabaseSchema] — создание таблиц и миграции;
/// - доменные DAO в `database/` — слой доступа к данным (плейлисты, история,
///   поиск, настройки, состояние плеера, бэкап);
/// - `AppDatabase` — точка входа: владеет соединением, миграцией
///   SharedPreferences и делегирует запросы в DAO (публичный контракт
///   сохранён для совместимости с репозиториями и тестами).
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  final PlaylistDao _playlistDao = PlaylistDao.instance;
  final ListenHistoryDao _listenHistoryDao = ListenHistoryDao.instance;
  final SearchHistoryDao _searchHistoryDao = SearchHistoryDao.instance;
  final SettingsDao _settingsDao = SettingsDao.instance;
  final PlaybackDao _playbackDao = PlaybackDao.instance;
  final BackupDao _backupDao = BackupDao.instance;

  Database? _db;

  /// Переопределение пути для тестов. Если задано — используется вместо
  /// `getApplicationDocumentsDirectory()`.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  static String? testDbPath;

  /// Путь, по которому лежит (или будет создан) файл базы.
  ///
  /// Используется `getApplicationDocumentsDirectory()` — стандартный каталог
  /// документов приложения. На Android этот каталог автоматически попадает
  /// в системный авто-бэкап (Android 6+), на iOS — бэкапится iCloud.
  Future<String> get _dbPath async {
    if (testDbPath != null) return testDbPath!;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, AppDatabaseSchema.dbName);
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
      version: AppDatabaseSchema.dbVersion,
      onCreate: AppDatabaseSchema.create,
      onUpgrade: AppDatabaseSchema.upgrade,
      onConfigure: (db) async {
        // WAL-mode: параллельные чтения не блокируются записью.
        // Не все версии sqflite/SQLite поддерживают WAL на всех платформах,
        // поэтому оборачиваем в try-catch.
        try {
          await db.execute('PRAGMA journal_mode = WAL');
        } catch (_) {}
      },
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

    // Фаза 2: SharedPreferences + история (v2, исправленные ключи)
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
                        jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
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
                  jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
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
  ///
  /// Статическая обёртка сохранена для совместимости с `PlayerService`.
  static Map<String, dynamic> extraPrimitives(Map<String, dynamic> extra) {
    return TrackRowCodec.extraPrimitives(extra);
  }

  // ==============================================================
  //  PLAYLISTS
  // ==============================================================

  /// Загружает все плейлисты (с треками и кастомными обложками) из БД,
  /// сортируя их «новые сверху».
  Future<List<Playlist>> loadPlaylists() async {
    return _playlistDao.loadPlaylists(await database);
  }

  /// Сохраняет (INSERT или REPLACE) плейлист и все его треки.
  Future<void> savePlaylist(Playlist playlist, int sortOrder) async {
    await _playlistDao.savePlaylist(await database, playlist, sortOrder);
  }

  /// Сохраняет все плейлисты разом (полный flush).
  Future<void> saveAllPlaylists(List<Playlist> playlists) async {
    await _playlistDao.saveAllPlaylists(await database, playlists);
  }

  /// Удаляет плейлист из БД.
  Future<void> deletePlaylist(String id) async {
    await _playlistDao.deletePlaylist(await database, id);
  }

  /// Полная очистка таблиц плейлистов (для тестов).
  @visibleForTesting
  Future<void> clearPlaylists() async {
    await _playlistDao.clearPlaylists(await database);
  }

  // ==============================================================
  //  LISTEN HISTORY
  // ==============================================================

  /// Возвращает историю прослушивания, новые сверху, с учётом лимита.
  Future<List<HistoryEntry>> loadListenHistory(int limit) async {
    return _listenHistoryDao.loadListenHistory(await database, limit);
  }

  /// Добавляет запись в историю (одну) и подрезает её до [limit] (если > 0)
  /// в той же транзакции — один коммит вместо двух.
  Future<void> addListenHistoryEntry(HistoryEntry entry, {int limit = 0}) async {
    await _listenHistoryDao.addListenHistoryEntry(
        await database, entry, limit: limit);
  }

  /// Удаляет конкретную запись из истории.
  Future<void> removeListenHistoryEntry(HistoryEntry entry) async {
    await _listenHistoryDao.removeListenHistoryEntry(await database, entry);
  }

  /// Очищает всю историю.
  Future<void> clearListenHistory() async {
    await _listenHistoryDao.clearListenHistory(await database);
  }

  /// Обновляет [artworkUrl] во всех записях истории для трека с указанным
  /// [globalId]. Используется после ленивой подгрузки обложки.
  Future<void> updateListenHistoryArtwork(
      String globalId, String? artworkUrl) async {
    await _listenHistoryDao.updateListenHistoryArtwork(
        await database, globalId, artworkUrl);
  }

  /// Подрезает историю до лимита (удаляет старые записи).
  Future<void> trimListenHistory(int limit) async {
    await _listenHistoryDao.trimListenHistory(await database, limit);
  }

  // ==============================================================
  //  SEARCH HISTORY
  // ==============================================================

  /// Возвращает историю поиска, новые сверху, не более [limit].
  Future<List<String>> getSearchHistory(int limit) async {
    return _searchHistoryDao.getSearchHistory(await database, limit);
  }

  /// Записывает историю поиска целиком (с дедупликацией и лимитом).
  Future<void> setSearchHistory(List<String> queries, int limit) async {
    await _searchHistoryDao.setSearchHistory(await database, queries, limit);
  }

  /// Добавляет поисковый запрос.
  Future<void> addSearchQuery(String query) async {
    await _searchHistoryDao.addSearchQuery(await database, query);
  }

  /// Удаляет конкретный поисковый запрос.
  Future<void> removeSearchQuery(String query) async {
    await _searchHistoryDao.removeSearchQuery(await database, query);
  }

  /// Очищает всю историю поиска.
  Future<void> clearSearchHistory() async {
    await _searchHistoryDao.clearSearchHistory(await database);
  }

  /// Подрезает историю поиска до лимита.
  Future<void> trimSearchHistory(int limit) async {
    await _searchHistoryDao.trimSearchHistory(await database, limit);
  }

  // ==============================================================
  //  SETTINGS
  // ==============================================================

  /// Читает значение настройки.
  Future<String?> getSetting(String key) async {
    return _settingsDao.getSetting(await database, key);
  }

  /// Записывает значение настройки.
  Future<void> setSetting(String key, String value) async {
    await _settingsDao.setSetting(await database, key, value);
  }

  /// Удаляет настройку.
  Future<void> removeSetting(String key) async {
    await _settingsDao.removeSetting(await database, key);
  }

  /// Возвращает все настройки в виде мапы.
  Future<Map<String, String>> getAllSettings() async {
    return _settingsDao.getAllSettings(await database);
  }

  /// Полная очистка кэша URL обложек (artwork_v3_*) из таблицы settings.
  Future<void> clearArtworkCacheDb() async {
    await _settingsDao.clearArtworkCacheDb(await database);
  }

  /// Удаляет все кэш-данные из SQLite, сохраняя пользовательские данные.
  Future<void> clearCacheData() async {
    await _settingsDao.clearCacheData(await database);
  }

  /// Ключ в таблице settings для кастомной обложки трека.
  static String customArtworkKey(String trackId) {
    return SettingsDao.customArtworkKey(trackId);
  }

  /// Возвращает путь к кастомной обложке трека из таблицы settings.
  Future<String?> getCustomArtworkPath(String trackId) async {
    return _settingsDao.getCustomArtworkPath(await database, trackId);
  }

  /// Сохраняет путь к кастомной обложке трека (REPLACE).
  Future<void> setCustomArtworkPath(String trackId, String path) async {
    await _settingsDao.setCustomArtworkPath(await database, trackId, path);
  }

  /// Удаляет запись о кастомной обложке трека.
  Future<void> removeCustomArtworkPath(String trackId) async {
    await _settingsDao.removeCustomArtworkPath(await database, trackId);
  }

  /// Возвращает все кастомные обложки (trackId -> path), которые есть на диске.
  Future<Map<String, String>> loadCustomArtworks(
      Set<String> existingFiles) async {
    return _settingsDao.loadCustomArtworks(await database, existingFiles);
  }

  /// Удаляет legacy-ключи custom_art_ (без версионного суффикса v1).
  Future<void> cleanupLegacyCustomArtKeys() async {
    await _settingsDao.cleanupLegacyCustomArtKeys(await database);
  }

  // ==============================================================
  //  PLAYBACK STATE (save / restore session)
  // ==============================================================

  /// Сохраняет текущую очередь и индекс в `playback_state`.
  Future<void> savePlaybackSession({
    required List<Map<String, dynamic>> queueRows,
    required int currentIndex,
    required int positionMs,
  }) async {
    await _playbackDao.savePlaybackSession(
        await database,
        queueRows: queueRows,
        currentIndex: currentIndex,
        positionMs: positionMs);
  }

  /// Загружает сохранённое состояние плеера.
  Future<({List<Track> queue, int currentIndex, int positionMs})?>
      loadPlaybackSession() async {
    return _playbackDao.loadPlaybackSession(await database);
  }

  // ==============================================================
  //  FULL BACKUP / RESTORE
  // ==============================================================

  /// Экспортирует всю БД в JSON-строку (полный бэкап).
  Future<String> exportFullBackup() async {
    return _backupDao.exportFullBackup(await database);
  }

  /// Импортирует полный бэкап из JSON-строки.
  Future<void> importFullBackup(String raw) async {
    await _backupDao.importFullBackup(await database, raw);
  }
}