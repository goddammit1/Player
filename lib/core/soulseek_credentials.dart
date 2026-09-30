// lib/core/soulseek_credentials.dart
//
// Фаза 4 — безопасное хранение учётных данных Soulseek.
//
// Пароль хранится ТОЛЬКО в flutter_secure_storage (Android Keystore) и
// НИКОГДА не попадает в SharedPreferences, SQLite, логи или plain-text.
// Username дополнительно дублируется в SQLite (ключ soulseek_username,
// таблица settings), чтобы экран настроек мог показывать его без
// обращения к Keystore (которое на некоторых устройствах требует
// разблокировки и занимает время).

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'database/app_database.dart';

/// Результат загрузки учётных данных: username + password.
typedef SoulseekCredentialPair = ({String username, String password});

/// Безопасное хранение учётных данных Soulseek.
///
/// Все методы статические; класс не предполагает инстанцирования.
/// Хранилище инициализируется лениво [FlutterSecureStorage].
class SoulseekCredentials {
  SoulseekCredentials._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Ключи secure storage ──
  static const String _keyUsername = 'soulseek_username';
  static const String _keyPassword = 'soulseek_password';

  // ── Ключ SQLite (только username, для быстрого отображения) ──
  static const String dbKeyUsername = 'soulseek_username';

  /// Загружает учётные данные из secure storage.
  ///
  /// Возвращает `null`, если данных нет или secure storage недоступен.
  /// Пароль читается исключительно из Keystore — никаких fallback-хранилищ.
  static Future<SoulseekCredentialPair?> load() async {
    try {
      final username = await _storage.read(key: _keyUsername);
      final password = await _storage.read(key: _keyPassword);
      if (username == null ||
          username.isEmpty ||
          password == null ||
          password.isEmpty) {
        return null;
      }
      return (username: username, password: password);
    } catch (e) {
      // secure storage может выбросить PlatformException, если Keystore
      // недоступен (например, на эмуляторе без заданного PIN). Не крашим
      // приложение — возвращаем null, UI покажет «введите данные».
      if (kDebugMode) debugPrint('[SoulseekCredentials] load failed: $e');
      return null;
    }
  }

  /// Сохраняет учётные данные в secure storage.
  ///
  /// Username дополнительно пишется в SQLite (ключ [dbKeyUsername]) для
  /// быстрого отображения в UI без разблокировки Keystore. Пароль —
  /// только в secure storage.
  static Future<void> save({
    required String username,
    required String password,
  }) async {
    try {
      await _storage.write(key: _keyUsername, value: username);
      await _storage.write(key: _keyPassword, value: password);

      // Дублируем username в SQLite (безопасно: username — не секрет,
      // его видно другим пользователям Soulseek в любом случае).
      await AppDatabase.instance.setSetting(dbKeyUsername, username);
    } catch (e) {
      if (kDebugMode) debugPrint('[SoulseekCredentials] save failed: $e');
      rethrow;
    }
  }

  /// Возвращает username из SQLite (быстро, без Keystore).
  ///
  /// Используется экраном настроек для предзаполнения поля username,
  /// пока пароль ещё не загружен. Возвращает `null`, если данных нет.
  static Future<String?> loadUsernameQuick() async {
    try {
      return await AppDatabase.instance.getSetting(dbKeyUsername);
    } catch (_) {
      return null;
    }
  }

  /// Удаляет и username, и password из всех хранилищ.
  static Future<void> clear() async {
    try {
      await _storage.delete(key: _keyUsername);
      await _storage.delete(key: _keyPassword);

      await AppDatabase.instance.removeSetting(dbKeyUsername);
    } catch (e) {
      if (kDebugMode) debugPrint('[SoulseekCredentials] clear failed: $e');
      rethrow;
    }
  }
}
