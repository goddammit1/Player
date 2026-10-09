import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import 'appearance_provider.dart';
import 'color_space.dart';
import 'dynamic_colors.dart';
import 'perceptual_colors.dart';
import '../artwork_image_provider.dart';
import '../providers.dart' show playerServiceProvider;

// ── Media item stream ──────────────────────────────────────────────────────

final _mediaItemProvider = StreamProvider<MediaItem?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem;
});

// ── Palette from artwork URL ───────────────────────────────────────────────

/// Ключ палитры: обложка и алгоритм, которым из неё извлекаются цвета.
typedef _PaletteKey = (String url, PaletteAlgorithm algorithm);

final _appColorsForUrlProvider =
    FutureProvider.autoDispose.family<AppColors, _PaletteKey>((ref, key) async {
  final (url, algorithm) = key;
  try {
    final imageProvider = artworkImageProvider(url);
    if (imageProvider == null) return AppColors.fixed;

    switch (algorithm) {
      case PaletteAlgorithm.classic:
        return await _classicColors(imageProvider);
      case PaletteAlgorithm.perceptual:
        final palette = await perceptualPaletteFromImage(imageProvider);
        return palette == null
            ? AppColors.fixed
            : AppColors.fromPerceptualPalette(palette);
    }
  } catch (e) {
    return AppColors.fixed;
  }
});

Future<AppColors> _classicColors(ImageProvider imageProvider) async {
  final palette = await PaletteGenerator.fromImageProvider(
    imageProvider,
    size: const Size(200, 200),
    maximumColorCount: 32,
    timeout: const Duration(seconds: 5),
  );

  final dynamicPalette = PaletteExtractor().fromPalette(palette);
  if (dynamicPalette == null) return AppColors.fixed;
  return AppColors.fromDynamicPalette(dynamicPalette);
}

// ── Current palette (instant, no animation) ────────────────────────────────

final currentPaletteProvider =
    StateNotifierProvider<CurrentPaletteNotifier, AppColors>((ref) {
  return CurrentPaletteNotifier(ref);
});

class CurrentPaletteNotifier extends StateNotifier<AppColors> {
  CurrentPaletteNotifier(this._ref) : super(AppColors.fixed) {
    _ref.listen(appThemeModeProvider, (_, _) => _recompute());
    _ref.listen(_mediaItemProvider, (_, _) => _recompute());
    _recompute();
  }

  final Ref _ref;
  ProviderSubscription<AsyncValue<AppColors>>? _paletteSub;

  /// Текущий ключ палитры; `null` — палитра фиксированная (начальное
  /// состояние нотифаера).
  _PaletteKey? _activeKey;

  void _recompute() {
    final algorithm = _ref.read(appThemeModeProvider).paletteAlgorithm;
    // Fixed-тема не зависит от плеера: медиа-поток читаем только для тем
    // из обложки (в виджет-тестах плеер не переопределён, и чтение бросает).
    final url = algorithm == null
        ? ''
        : (_ref.read(_mediaItemProvider).value?.artUri?.toString() ?? '');
    final key = (algorithm == null || url.isEmpty) ? null : (url, algorithm);

    if (key == _activeKey) return;
    _activeKey = key;

    _paletteSub?.close();
    _paletteSub = null;

    if (key == null) {
      state = AppColors.fixed;
      return;
    }

    _paletteSub = _ref.listen(
      _appColorsForUrlProvider(key),
      (_, asyncColors) {
        asyncColors.whenData((colors) => state = colors);
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _paletteSub?.close();
    super.dispose();
  }
}

// ── Animated palette ───────────────────────────────────────────────────────

final animatedPaletteProvider =
    StateNotifierProvider<AnimatedPaletteNotifier, AppColors>((ref) {
  return AnimatedPaletteNotifier(ref);
});

/// Плавный переход между палитрами.
///
/// Ticker вместо Timer(16ms): тики синхронизированы с vsync — ровно одно
/// обновление на реальный кадр, без дрейфа таймера и без лишних срабатываний,
/// когда кадры не рисуются.
class AnimatedPaletteNotifier extends StateNotifier<AppColors> {
  AnimatedPaletteNotifier(this._ref)
      : super(_ref.read(currentPaletteProvider)) {
    _ticker = Ticker(_onTick);
    _ref.listen(currentPaletteProvider, (previous, next) {
      if (next == (_target ?? state)) return;
      _start = state;
      _target = next;
      _ticker.stop();
      _ticker.start();
    });
  }

  final Ref _ref;
  late final Ticker _ticker;
  AppColors _start = AppColors.fixed;
  AppColors? _target;
  static const _duration = Duration(milliseconds: 1000);

  void _onTick(Duration elapsed) {
    final target = _target;
    if (target == null) {
      _ticker.stop();
      return;
    }

    final t =
        (elapsed.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    if (t >= 1.0) {
      _ticker.stop();
      _target = null;
      state = target;
      return;
    }

    state = AppColors.lerp(_start, target, Curves.easeInOutCubic.transform(t));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

// ── AppColors ──────────────────────────────────────────────────────────────

@immutable
class AppColors {
  const AppColors._({
    required this.background,
    required this.elevated,
    required this.elevatedVariant,
    required this.elevatedHi,
    required this.elevatedProgressBar,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.gradientTop,
    required this.gradientBottom,
    required this.meshColors,
    required this.isDynamic,
  });

  static const fixed = AppColors._(
    background: Color(0xFF000000),
    elevated: Color(0xFF161618),
    elevatedVariant: Color(0xFF212124),
    elevatedHi: Color(0xFF747474),
    elevatedProgressBar: Color(0x66747474),
    outline: Color(0xFF2F2F2F),
    textPrimary: Color(0xFFF9F8F8),
    textSecondary: Color(0xB3F9F8F8),
    textTertiary: Color(0x80F9F8F8),
    accent: Color(0xFF747474),
    gradientTop: Color(0xFF000000),
    gradientBottom: Color(0xFF000000),
    meshColors: [
      Color(0xFF000000),
      Color(0xFF161618),
      Color(0xFF747474),
      Color(0xFF000000),
    ],
    isDynamic: false,
  );

  /// Строит палитру приложения из [DynamicPalette] — гибридного экстрактора
  /// (ArchiveTune + ViTune + ViViMusic) из dynamic_colors.dart.
  /// Прежний упрощённый экстрактор «самый насыщенный swatch» удалён —
  /// источник цветов теперь один.
  factory AppColors.fromDynamicPalette(DynamicPalette p) {
    return AppColors._(
      background: Color.lerp(p.gradientTop, p.gradientBottom, 0.6)!,
      elevated: p.elevated,
      elevatedVariant: _darken(p.elevated, 0.05),
      elevatedHi: p.accent,
      elevatedProgressBar: p.accent.withValues(alpha: 0.5),
      outline: _lighten(p.elevated, 0.15),
      textPrimary: p.primary,
      textSecondary: const Color(0xB3F9F8F8),
      textTertiary: const Color(0x80F9F8F8),
      accent: p.accent,
      gradientTop: p.gradientTop,
      gradientBottom: p.gradientBottom,
      meshColors: List.unmodifiable(
        [p.gradientTop, p.elevated, p.accent, p.gradientBottom],
      ),
      isDynamic: true,
    );
  }

  /// Строит палитру приложения из [PerceptualPalette] (perceptual_colors.dart):
  /// роли на HCT с гарантированным контрастом.
  factory AppColors.fromPerceptualPalette(PerceptualPalette p) {
    return AppColors._(
      background: p.background,
      elevated: p.elevated,
      elevatedVariant: p.elevatedVariant,
      elevatedHi: p.elevatedHi,
      elevatedProgressBar: p.elevatedHi.withValues(alpha: 0.4),
      outline: p.outline,
      textPrimary: p.textPrimary,
      textSecondary: p.textPrimary.withValues(alpha: 0.7),
      textTertiary: p.textPrimary.withValues(alpha: 0.5),
      accent: p.accent,
      gradientTop: p.gradientTop,
      gradientBottom: p.gradientBottom,
      meshColors: p.meshColors,
      isDynamic: true,
    );
  }

  final Color background;
  final Color elevated;
  final Color elevatedVariant;
  final Color elevatedHi;
  final Color elevatedProgressBar;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color gradientTop;
  final Color gradientBottom;

  /// [meshColorCount] цветов для mesh-фона страницы плеера.
  final List<Color> meshColors;
  final bool isDynamic;

  /// Цвета смешиваются в OKLCh: конечные палитры те же, что с [Color.lerp],
  /// но середина перехода не проваливается в серое.
  static AppColors lerp(AppColors a, AppColors b, double t) {
    return AppColors._(
      background: lerpOklch(a.background, b.background, t),
      elevated: lerpOklch(a.elevated, b.elevated, t),
      elevatedVariant: lerpOklch(a.elevatedVariant, b.elevatedVariant, t),
      elevatedHi: lerpOklch(a.elevatedHi, b.elevatedHi, t),
      elevatedProgressBar:
          lerpOklch(a.elevatedProgressBar, b.elevatedProgressBar, t),
      outline: lerpOklch(a.outline, b.outline, t),
      textPrimary: lerpOklch(a.textPrimary, b.textPrimary, t),
      textSecondary: lerpOklch(a.textSecondary, b.textSecondary, t),
      textTertiary: lerpOklch(a.textTertiary, b.textTertiary, t),
      accent: lerpOklch(a.accent, b.accent, t),
      gradientTop: lerpOklch(a.gradientTop, b.gradientTop, t),
      gradientBottom: lerpOklch(a.gradientBottom, b.gradientBottom, t),
      meshColors: List.unmodifiable([
        for (var i = 0; i < meshColorCount; i++)
          lerpOklch(a.meshColors[i], b.meshColors[i], t),
      ]),
      isDynamic: t > 0.5 ? b.isDynamic : a.isDynamic,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppColors &&
          background == other.background &&
          elevated == other.elevated &&
          elevatedVariant == other.elevatedVariant &&
          elevatedHi == other.elevatedHi &&
          elevatedProgressBar == other.elevatedProgressBar &&
          outline == other.outline &&
          textPrimary == other.textPrimary &&
          textSecondary == other.textSecondary &&
          textTertiary == other.textTertiary &&
          accent == other.accent &&
          gradientTop == other.gradientTop &&
          gradientBottom == other.gradientBottom &&
          listEquals(meshColors, other.meshColors) &&
          isDynamic == other.isDynamic;

  @override
  int get hashCode => Object.hash(
        background,
        elevated,
        elevatedVariant,
        elevatedHi,
        elevatedProgressBar,
        outline,
        textPrimary,
        textSecondary,
        textTertiary,
        accent,
        gradientTop,
        gradientBottom,
        Object.hashAll(meshColors),
        isDynamic,
      );

  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }
}
