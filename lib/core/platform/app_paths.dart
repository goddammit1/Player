// lib/core/platform/app_paths.dart
//
// Каталоги данных приложения по платформам (этап 4.1 плана паритета).
//
// Android/iOS — без изменений: данные в Documents (авто-бэкап Android /
// iCloud), кэш во временном каталоге.
//
// Windows:
// - данные (БД, кастомные обложки) — `%APPDATA%\com.player\player`
//   (`getApplicationSupportDirectory`, CompanyName\ProductName из Runner.rc),
//   а не «Документы» пользователя;
// - аудиокэш с закреплёнными («офлайн») треками —
//   `%LOCALAPPDATA%\com.player\player`, а не `%TEMP%`, который чистит
//   «Очистка диска». Там же кэш Soulseek (`soulseek_cache`).
//
// Перенос со старых путей — `WindowsDataMigration`.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths._();

  static Directory? _dataOverride;
  static Directory? _cacheOverride;

  /// Подменяет каталог данных. Используется миграцией, когда БД не удалось
  /// перенести со старого места (данные остаются там до следующего старта),
  /// и тестами. `null` — платформенный каталог по умолчанию.
  static void overrideDataDir(Directory? dir) => _dataOverride = dir;

  /// Тестовый хук: подменяет постоянный каталог кэша.
  @visibleForTesting
  static void setCacheDirForTesting(Directory? dir) => _cacheOverride = dir;

  /// Постоянные данные: БД, кастомные обложки, авто-бэкапы.
  static Future<Directory> dataDir() async {
    final override = _dataOverride;
    if (override != null) return override;
    if (Platform.isWindows) return getApplicationSupportDirectory();
    return getApplicationDocumentsDirectory();
  }

  /// Аудиокэш (в т.ч. закреплённые треки). На мобильных — временный
  /// каталог, как раньше; на Windows — постоянный в `%LOCALAPPDATA%`.
  static Future<Directory> cacheDir() async {
    final override = _cacheOverride;
    if (override != null) return override;
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        return Directory(p.join(local, 'com.player', 'player'));
      }
      return Directory(
          p.join((await getApplicationSupportDirectory()).path, 'cache'));
    }
    return getTemporaryDirectory();
  }

  /// Каталог данных Windows до этапа 4.1 («Документы»): источник миграции
  /// и запасное место поиска авто-бэкапа.
  static Future<Directory> legacyWindowsDataDir() =>
      getApplicationDocumentsDirectory();
}
