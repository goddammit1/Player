import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:player/core/app_database.dart';

class TestHarness {
  TestHarness._();

  static bool _initialized = false;

  /// Текущий temp-каталог. Создаётся один раз в [setUpDb] и удаляется
  /// в [tearDownDb]. Между [setUpDb] и [tearDownDb] можно закрывать и
  /// переоткрывать БД сколько угодно — путь не меняется.
  static String? _currentTempDir;

  static void ensureInitialized() {
    if (_initialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _initialized = true;
  }

  /// Подключает AppDatabase к временной БД.
  ///
  /// При первом вызове (или после [tearDownDb]) создаёт новый temp-каталог.
  /// Повторные вызовы **без** [tearDownDb] переиспользуют тот же файл,
  /// что позволяет тестировать «переоткрытие БД с сохранением данных».
  static Future<void> setUpDb() async {
    // Закрываем текущее подключение (если было).
    await AppDatabase.instance.close();
    AppDatabase.testDbPath = null;

    if (_currentTempDir != null) {
      // Повторный вызов: переиспользуем существующий каталог.
      AppDatabase.testDbPath = p.join(_currentTempDir!, 'player_data.db');
      return;
    }

    // Первый вызов: создаём свежий temp-каталог.
    _currentTempDir =
        Directory.systemTemp.createTempSync('player_test_').path;
    AppDatabase.testDbPath = p.join(_currentTempDir!, 'player_data.db');
  }

  static Future<void> tearDownDb() async {
    await AppDatabase.instance.close();
    AppDatabase.testDbPath = null;
    if (_currentTempDir != null) {
      try {
        await Directory(_currentTempDir!).delete(recursive: true);
      } catch (_) {}
      _currentTempDir = null;
    }
  }
}

