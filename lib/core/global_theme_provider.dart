import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import 'appearance_provider.dart';
import 'dynamic_colors.dart';
import 'providers.dart' show playerServiceProvider;

// ── Media item stream ──────────────────────────────────────────────────────

final _mediaItemProvider = StreamProvider<MediaItem?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem;
});

// ── Palette from artwork URL ───────────────────────────────────────────────
//
// autoDispose: палитры старых обложек освобождаются, как только на них никто
// не подписан (подписку на текущий URL держит CurrentPaletteNotifier).
// size: PaletteGenerator квантует уменьшенную копию картинки — тот же
// результат, но без десятков миллисекунд jank в main isolate.
// CachedNetworkImageProvider: общий кэш с cached_network_image, которым
// обложки уже загружены в UI — без повторного похода в сеть.
final _appColorsForUrlProvider =
    FutureProvider.autoDispose.family<AppColors, String>((ref, url) async {
  final palette = await PaletteGenerator.fromImageProvider(
    CachedNetworkImageProvider(url),
    size: const Size(200, 200),
    maximumColorCount: 32,
    timeout: const Duration(seconds: 5),
  );
  final extractor = PaletteExtractor();
  final dynamicPalette = extractor.fromPalette(palette);
  if (dynamicPalette == null) return AppColors.fixed;
  return AppColors.fromDynamicPalette(dynamicPalette);
});

// ── Current palette (instant, no animation) ────────────────────────────────

final currentPaletteProvider =
    StateNotifierProvider<CurrentPaletteNotifier, AppColors>((ref) {
  return CurrentPaletteNotifier(ref);
});

/// Мгновенная (неанимированная) палитра.
///
/// Держит last-good значение: пока палитра нового трека считается (или упала
/// с ошибкой), остаёмся на предыдущей — без «вспышки» чёрной fixed-темы при
/// каждой смене трека.
class CurrentPaletteNotifier extends StateNotifier<AppColors> {
  CurrentPaletteNotifier(this._ref) : super(AppColors.fixed) {
    _ref.listen(appThemeModeProvider, (_, _) => _recompute());
    _ref.listen(_mediaItemProvider, (_, _) => _recompute());
    _recompute();
  }

  final Ref _ref;
  ProviderSubscription<AsyncValue<AppColors>>? _paletteSub;
  String? _activeUrl;

  void _recompute() {
    final mode = _ref.read(appThemeModeProvider);
    final url = mode == AppThemeMode.dynamic
        ? (_ref.read(_mediaItemProvider).value?.artUri?.toString() ?? '')
        : '';

    if (url == _activeUrl) return;
    _activeUrl = url;

    _paletteSub?.close();
    _paletteSub = null;

    if (url.isEmpty) {
      state = AppColors.fixed;
      return;
    }

    // Открытая подписка держит autoDispose-запись текущего URL живой —
    // аналог keepAlive для активного трека.
    _paletteSub = _ref.listen(
      _appColorsForUrlProvider(url),
      (_, asyncColors) {
        // data → новая палитра; loading/error → остаёмся на last-good.
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
  final bool isDynamic;

  static AppColors lerp(AppColors a, AppColors b, double t) {
    return AppColors._(
      background: Color.lerp(a.background, b.background, t)!,
      elevated: Color.lerp(a.elevated, b.elevated, t)!,
      elevatedVariant: Color.lerp(a.elevatedVariant, b.elevatedVariant, t)!,
      elevatedHi: Color.lerp(a.elevatedHi, b.elevatedHi, t)!,
      elevatedProgressBar:
          Color.lerp(a.elevatedProgressBar, b.elevatedProgressBar, t)!,
      outline: Color.lerp(a.outline, b.outline, t)!,
      textPrimary: Color.lerp(a.textPrimary, b.textPrimary, t)!,
      textSecondary: Color.lerp(a.textSecondary, b.textSecondary, t)!,
      textTertiary: Color.lerp(a.textTertiary, b.textTertiary, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
      gradientTop: Color.lerp(a.gradientTop, b.gradientTop, t)!,
      gradientBottom: Color.lerp(a.gradientBottom, b.gradientBottom, t)!,
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
