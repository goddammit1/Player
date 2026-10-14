// lib/core/platform/windows_data_migration.dart
//
// Одноразовый перенос данных Windows со старых путей (этап 4.1 плана
// паритета, см. [AppPaths]):
// - `Документы\player_data.db` (+ -wal/-shm/-journal) и
//   `Документы\custom_artworks\` → `%APPDATA%\com.player\player\`;
// - `%TEMP%\yt_audio_cache\` → `%LOCALAPPDATA%\com.player\player\`.
//
// Выполняется при старте до открытия БД. Каждый шаг идемпотентен, так что
// прерванный перенос докатывается при следующем запуске. Если БД перенести
// не удалось (её держит открытой другой экземпляр приложения), данные
// остаются на старом месте и приложение работает с ними до следующего
// старта. Android-пути не меняются.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../database/database_schema.dart';
import 'app_paths.dart';

class WindowsDataMigration {
  WindowsDataMigration({
    required this.legacyDataDir,
    required this.dataDir,
    required this.legacyCacheDir,
    required this.cacheDir,
  });

  final Directory legacyDataDir;
  final Directory dataDir;
  final Directory legacyCacheDir;
  final Directory cacheDir;

  /// Отметка в `settings`: абсолютные пути в БД переписаны на новый каталог.
  /// Префикс `migration_` не мешает [AppDatabase.isEmptyForImport].
  static const String markerKey = 'migration_windows_paths_v1';

  static const String _artworkDirName = 'custom_artworks';
  static const String _audioDirName = 'yt_audio_cache';

  /// Файл БД первым: при неудаче на нём остальные не трогаются.
  static const List<String> _dbSuffixes = ['', '-wal', '-shm', '-journal'];

  /// Точка входа из main: вызывать после инициализации sqflite FFI и до
  /// первого обращения к БД, кастомным обложкам и аудиокэшу.
  static Future<void> runOnStartup() async {
    if (!Platform.isWindows) return;
    WindowsDataMigration? migration;
    var dbInPlace = false;
    try {
      migration = WindowsDataMigration(
        legacyDataDir: await AppPaths.legacyWindowsDataDir(),
        dataDir: await AppPaths.dataDir(),
        legacyCacheDir: await getTemporaryDirectory(),
        cacheDir: await AppPaths.cacheDir(),
      );
      dbInPlace = await migration.moveDatabase();
      if (dbInPlace) {
        await migration.moveCustomArtwork();
        await migration.rewriteStoredPaths(AppDatabase.instance);
      } else {
        debugPrint('[WindowsDataMigration] database is busy, '
            'keeping data in ${migration.legacyDataDir.path} for this run');
        AppPaths.overrideDataDir(migration.legacyDataDir);
      }
      await migration.moveAudioCache();
    } catch (e) {
      debugPrint('[WindowsDataMigration] failed: $e');
      // БД так и не переехала — не показывать пользователю пустую новую.
      final legacy = migration?.legacyDataDir;
      if (!dbInPlace && legacy != null && migration!._legacyDbOnly()) {
        AppPaths.overrideDataDir(legacy);
      }
    }
  }

  bool _legacyDbOnly() =>
      File(p.join(legacyDataDir.path, AppDatabaseSchema.dbName))
          .existsSync() &&
      !File(p.join(dataDir.path, AppDatabaseSchema.dbName)).existsSync();

  /// Переносит файл БД вместе с -wal/-shm/-journal. `false` — БД осталась
  /// на старом месте (занята другим процессом или ошибка ввода-вывода),
  /// уже перенесённые части возвращены обратно.
  Future<bool> moveDatabase() async {
    if (p.equals(legacyDataDir.path, dataDir.path)) return true;
    final from = p.join(legacyDataDir.path, AppDatabaseSchema.dbName);
    final to = p.join(dataDir.path, AppDatabaseSchema.dbName);
    if (!await File(from).exists()) return true;
    if (await File(to).exists()) {
      // Обе БД на месте: новая главнее, старую не трогаем.
      debugPrint('[WindowsDataMigration] both $from and $to exist, '
          'keeping the new one');
      return true;
    }
    final moved = <(File, File)>[];
    for (final suffix in _dbSuffixes) {
      final src = File('$from$suffix');
      if (!await src.exists()) continue;
      final dst = File('$to$suffix');
      if (await _moveFile(src, dst, strict: true)) {
        moved.add((src, dst));
        continue;
      }
      for (final (original, copy) in moved.reversed) {
        await _moveFile(copy, original, strict: true);
      }
      return false;
    }
    return true;
  }

  Future<void> moveCustomArtwork() => _moveTree(
        Directory(p.join(legacyDataDir.path, _artworkDirName)),
        Directory(p.join(dataDir.path, _artworkDirName)),
      );

  /// Недокачанные `.part` не переносятся — удаляются.
  Future<void> moveAudioCache() => _moveTree(
        Directory(p.join(legacyCacheDir.path, _audioDirName)),
        Directory(p.join(cacheDir.path, _audioDirName)),
        discard: (f) => f.path.endsWith('.part'),
      );

  /// Переписывает абсолютные пути кастомных обложек, сохранённые в БД
  /// (настройки, обложки плейлистов, треки в JSON), на новый каталог.
  Future<void> rewriteStoredPaths(AppDatabase db) async {
    if (await db.getSetting(markerKey) != null) return;
    final changed = await db.replaceInAllText(
      pathRewrites(legacyDataDir.path, dataDir.path),
    );
    if (changed > 0) {
      debugPrint('[WindowsDataMigration] rewrote $changed stored paths');
    }
    await db.setSetting(markerKey, '1');
  }

  /// Пары «было → стало» для путей внутри `custom_artworks`. Пути в коде
  /// собираются и через `\`, и через `/`; в JSON обратный слэш экранирован.
  @visibleForTesting
  static List<(String, String)> pathRewrites(String from, String to) {
    String json(String s) => s.replaceAll(r'\', r'\\');
    return [
      for (final sep in const [r'\', '/'])
        ('$from$sep$_artworkDirName', '$to$sep$_artworkDirName'),
      for (final sep in const [r'\\', '/'])
        ('${json(from)}$sep$_artworkDirName', '${json(to)}$sep$_artworkDirName'),
    ];
  }

  /// Пофайловый перенос содержимого [from] в [to]. Файл, уже лежащий в [to],
  /// главнее: дубль в [from] удаляется. Опустевшие каталоги удаляются.
  static Future<void> _moveTree(
    Directory from,
    Directory to, {
    bool Function(File file)? discard,
  }) async {
    if (p.equals(from.path, to.path) || !await from.exists()) return;
    final entities = await from.list(recursive: true, followLinks: false).toList();
    for (final file in entities.whereType<File>()) {
      final dst = File(p.join(to.path, p.relative(file.path, from: from.path)));
      if ((discard?.call(file) ?? false) || await dst.exists()) {
        try {
          await file.delete();
        } on FileSystemException catch (_) {}
        continue;
      }
      await _moveFile(file, dst, strict: false);
    }
    final dirs = entities.whereType<Directory>().toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final dir in [...dirs, from]) {
      try {
        await dir.delete();
      } on FileSystemException catch (_) {
        // Не пуст — что-то не перенеслось; оставляем.
      }
    }
  }

  /// `rename`, а при неудаче (другой том) — копия + удаление оригинала.
  /// [strict]: оригинал обязан исчезнуть, иначе копия удаляется и
  /// возвращается `false`. Нужен для БД: если её держит открытой другой
  /// экземпляр приложения, копировать нельзя — данные разъедутся.
  static Future<bool> _moveFile(File src, File dst, {required bool strict}) async {
    try {
      await dst.parent.create(recursive: true);
      await src.rename(dst.path);
      return true;
    } on FileSystemException catch (_) {}
    try {
      await src.copy(dst.path);
    } on FileSystemException catch (e) {
      debugPrint('[WindowsDataMigration] copy ${src.path} failed: $e');
      await _deleteQuietly(dst);
      return false;
    }
    try {
      await src.delete();
    } on FileSystemException catch (e) {
      if (strict) {
        debugPrint('[WindowsDataMigration] ${src.path} is busy: $e');
        await _deleteQuietly(dst);
        return false;
      }
    }
    return true;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (_) {}
  }
}
