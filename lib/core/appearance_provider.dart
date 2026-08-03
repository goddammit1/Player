import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// Тип темы приложения.
enum AppThemeMode {
  /// Цвета берутся из обложки текущего трека.
  dynamic,
  /// Фиксированная чёрно-серая палитра (как сейчас).
  fixed,
}

/// Провайдер для хранения выбранного режима темы.
///
/// Используем StateNotifier, чтобы иметь асинхронную инициализацию
/// из SQLite и возможность сохранять выбор на диск.
final appThemeModeProvider =
    StateNotifierProvider<AppThemeModeNotifier, AppThemeMode>((ref) {
  return AppThemeModeNotifier();
});

class AppThemeModeNotifier extends StateNotifier<AppThemeMode> {
  // Устанавливаем дефолтный режим AppThemeMode.dynamic, если пользователь еще не делал выбор
  AppThemeModeNotifier() : super(AppThemeMode.dynamic) {
    _load();
  }

  static const _key = 'app_theme_mode';

  Future<void> _load() async {
    final saved = await AppDatabase.instance.getSetting(_key);
    if (saved != null) {
      final mode = AppThemeMode.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => AppThemeMode.dynamic,
      );
      state = mode;
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    await AppDatabase.instance.setSetting(_key, mode.name);
  }

  Future<void> toggle() async {
    final next = state == AppThemeMode.fixed
        ? AppThemeMode.dynamic
        : AppThemeMode.fixed;
    await setMode(next);
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}
