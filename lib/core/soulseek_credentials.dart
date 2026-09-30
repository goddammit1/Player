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
import 'package:flutter/services.dart';
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

  /// Диагностика: проверка secure storage через тот же [FlutterSecureStorage]
  /// (те же AndroidOptions), что и у учётных данных.
  ///
  /// Пишет, читает и удаляет служебный ключ с константным значением.
  /// Учётные данные не читаются: в отчёт попадает только факт их наличия
  /// (containsKey), значения — никогда.
  static Future<String> diagnosticRoundTrip() async {
    const probeKey = '__diagnostics_probe__';
    const probeValue = 'probe';
    final out = StringBuffer();

    Future<bool> step(String name, Future<String?> Function() op) async {
      try {
        final detail = await op();
        out.writeln('[OK]   $name${detail == null ? '' : ': $detail'}');
        return true;
      } catch (e) {
        out.writeln('[FAIL] $name');
        out.writeln(_describeError(e));
        return false;
      }
    }

    await step('stored credentials', () async {
      final hasUsername = await _storage.containsKey(key: _keyUsername);
      final hasPassword = await _storage.containsKey(key: _keyPassword);
      return 'username ${hasUsername ? 'present' : 'absent'}, '
          'password ${hasPassword ? 'present' : 'absent'}';
    });
    final written = await step('write probe', () async {
      await _storage.write(key: probeKey, value: probeValue);
      return null;
    });
    if (written) {
      await step('read probe back', () async {
        final value = await _storage.read(key: probeKey);
        if (value != probeValue) {
          throw StateError(
            value == null ? 'read returned null' : 'read returned a different value',
          );
        }
        return null;
      });
    }
    await step('delete probe', () async {
      await _storage.delete(key: probeKey);
      return null;
    });
    return out.toString();
  }

  /// PlatformException плагина несёт Java-стек в `details`.
  static String _describeError(Object e) {
    final text = e is PlatformException
        ? 'PlatformException(${e.code}): ${e.message}\n${e.details ?? ''}'
        : e.toString();
    final lines = text.trimRight().split('\n');
    const maxLines = 30;
    return [
      for (final line in lines.take(maxLines)) '       $line',
      if (lines.length > maxLines) '       … ${lines.length - maxLines} more lines',
    ].join('\n');
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
