import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';

/// Алгоритм, которым цвета интерфейса извлекаются из обложки.
enum PaletteAlgorithm {
  /// Прежний HSL-экстрактор поверх palette_generator (dynamic_colors.dart).
  classic,

  /// Перцептивный алгоритм на HCT (material_color_utilities).
  perceptual,
}

/// Фон страницы плеера.
enum PlayerBackgroundStyle { gradient, mesh, blur }

/// Тема приложения.
///
/// Значение хранится в БД по [name], поэтому имена существующих значений
/// менять нельзя: `dynamic` — это тема Classic, под этим именем её сохранили
/// пользователи прежних версий.
enum AppThemeMode {
  /// Фиксированная чёрно-серая палитра.
  fixed(null, PlayerBackgroundStyle.gradient),

  /// Classic: цвета из обложки прежним алгоритмом.
  dynamic(PaletteAlgorithm.classic, PlayerBackgroundStyle.gradient),

  /// Цвета из обложки перцептивным алгоритмом.
  perceptual(PaletteAlgorithm.perceptual, PlayerBackgroundStyle.gradient),

  /// Perceptual + анимированный mesh из цветов обложки на странице плеера.
  mesh(PaletteAlgorithm.perceptual, PlayerBackgroundStyle.mesh),

  /// Perceptual + размытая обложка на странице плеера.
  blur(PaletteAlgorithm.perceptual, PlayerBackgroundStyle.blur);

  const AppThemeMode(this.paletteAlgorithm, this.playerBackground);

  /// Алгоритм извлечения цветов; `null` — цвета не зависят от обложки.
  final PaletteAlgorithm? paletteAlgorithm;

  final PlayerBackgroundStyle playerBackground;
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
  // Дефолт — фиксированная чёрно-серая палитра, как требует дизайн-контракт
  // (см. main.dart: «никакого цветного акцента»). Раньше по умолчанию была
  // dynamic-тема, и при жёлтой обложке трека вся панель (слайдер, бордеры,
  // разделители) заливалась производными цветами обложки. Пользователь
  // может включить dynamic в настройках — выбор сохраняется в БД.
  AppThemeModeNotifier() : super(AppThemeMode.fixed) {
    _ready = _load();
  }

  /// Завершается после окончания инициализации (нужно в тестах для
  /// детерминизма вместо `Future.delayed(Duration.zero)`).
  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  static const _key = 'app_theme_mode';

  Future<void> _load() async {
    final saved = await AppDatabase.instance.getSetting(_key);
    if (saved != null) {
      final mode = AppThemeMode.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => AppThemeMode.fixed,
      );
      state = mode;
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    await AppDatabase.instance.setSetting(_key, mode.name);
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}
