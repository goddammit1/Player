import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// DAO настроек: key-value операции над таблицей `settings`, включая
/// кэш обложек (artwork_v3_*) и кастомные обложки (custom_art_v*).
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
class SettingsDao {
  SettingsDao._();
  static final SettingsDao instance = SettingsDao._();

  /// Читает значение настройки.
  Future<String?> getSetting(Database db, String key) async {
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
  Future<void> setSetting(Database db, String key, String value) async {
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
  Future<void> removeSetting(Database db, String key) async {
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Возвращает все настройки в виде мапы.
  Future<Map<String, String>> getAllSettings(Database db) async {
    final rows = await db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  /// Полная очистка кэша URL обложек (artwork_v3_*) из таблицы settings.
  ///
  /// Удаляет все записи, которые ArtworkProvider сохраняет как результат
  /// поиска обложек через Genius / iTunes. После очистки обложки будут
  /// перезапрошены заново при следующем воспроизведении трека.
  Future<void> clearArtworkCacheDb(Database db) async {
    await db.delete(
      'settings',
      where: "key LIKE 'artwork_v3_%'",
    );
  }

  /// Удаляет все кэш-данные из SQLite, сохраняя пользовательские данные
  /// (плейлисты, историю прослушивания, настройки приложения).
  ///
  /// Очищает:
  /// - artwork URL cache (artwork_v3_*)
  /// - custom artwork cache (custom_art_v*)
  Future<void> clearCacheData(Database db) async {
    await db.delete('settings', where: "key LIKE 'artwork_v3_%'");
    await db.delete('settings', where: "key LIKE 'custom_art_v%'");
  }

  /// Ключ в таблице settings для кастомной обложки трека.
  static String customArtworkKey(String trackId) => 'custom_art_v1_$trackId';

  /// Возвращает путь к кастомной обложке трека из таблицы settings.
  /// null — обложка не установлена.
  Future<String?> getCustomArtworkPath(Database db, String trackId) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [customArtworkKey(trackId)],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final val = rows.first['value'] as String?;
      if (val != null && val.isNotEmpty) return val;
    }
    return null;
  }

  /// Сохраняет путь к кастомной обложке трека (REPLACE).
  Future<void> setCustomArtworkPath(
      Database db, String trackId, String path) async {
    await db.insert(
      'settings',
      {'key': customArtworkKey(trackId), 'value': path},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Удаляет запись о кастомной обложке трека.
  Future<void> removeCustomArtworkPath(Database db, String trackId) async {
    await db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: [customArtworkKey(trackId)],
    );
  }

  /// Возвращает все кастомные обложки (trackId -> path), которые есть на диске.
  /// [existingFiles] — set путей, реально существующих (проверено вызывающей стороной).
  Future<Map<String, String>> loadCustomArtworks(
      Database db, Set<String> existingFiles) async {
    final rows = await db.query(
      'settings',
      columns: ['key', 'value'],
      where: "key LIKE 'custom_art_v1_%'",
    );
    final result = <String, String>{};
    for (final row in rows) {
      final key = row['key'] as String;
      final trackId = key.replaceFirst('custom_art_v1_', '');
      final path = row['value'] as String;
      if (path.isNotEmpty && existingFiles.contains(path)) {
        result[trackId] = path;
      }
    }
    return result;
  }

  /// Удаляет legacy-ключи custom_art_ (без версионного суффикса v1).
  Future<void> cleanupLegacyCustomArtKeys(Database db) async {
    await db.delete(
      'settings',
      where: "key LIKE 'custom_art_%' AND key NOT LIKE 'custom_art_v%'",
    );
  }
}