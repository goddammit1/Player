import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// из SharedPreferences и возможность сохранять выбор на диск.
final appThemeModeProvider =
    StateNotifierProvider<AppThemeModeNotifier, AppThemeMode>((ref) {
  return AppThemeModeNotifier();
});

class AppThemeModeNotifier extends StateNotifier<AppThemeMode> {
  AppThemeModeNotifier() : super(AppThemeMode.fixed) {
    _load();
  }

  static const _key = 'app_theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      state = AppThemeMode.values.byName(raw);
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  /// Переключить между dynamic ↔ fixed.
  Future<void> toggle() async {
    final next = state == AppThemeMode.fixed
        ? AppThemeMode.dynamic
        : AppThemeMode.fixed;
    await setMode(next);
  }
}
