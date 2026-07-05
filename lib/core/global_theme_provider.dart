import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:audio_service/audio_service.dart';

import 'providers.dart';  // для playerServiceProvider

// ── Media item stream ──────────────────────────────────────────────────────

final _mediaItemProvider = StreamProvider<MediaItem?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem;
});

// ── Async palette from URL ─────────────────────────────────────────────────

final _asyncPaletteProvider = FutureProvider.family<PaletteGenerator, String>((ref, url) async {
  if (url.isEmpty) throw Exception('Empty URL');
  return await PaletteGenerator.fromImageProvider(
    NetworkImage(url),
    maximumColorCount: 24,
    timeout: const Duration(seconds: 5),
  );
});

// ── Current palette (instant, no animation) ────────────────────────────────

final currentPaletteProvider = Provider<AppColors>((ref) {
  final mode = ref.watch(appThemeModeProvider);
  if (mode == AppThemeMode.fixed) return AppColors.fixed;

  final mediaItem = ref.watch(_mediaItemProvider);
  final url = mediaItem.value?.artUri?.toString();
  if (url == null || url.isEmpty) return AppColors.fixed;

  final paletteAsync = ref.watch(_asyncPaletteProvider(url));
  return paletteAsync.when(
    data: (palette) => AppColors.fromPalette(palette),
    loading: () => AppColors.fixed,
    error: (_, _) => AppColors.fixed,
  );
});

// ── Animated palette — StateNotifierProvider (совместим с существующим кодом) ─

final animatedPaletteProvider = StateNotifierProvider<AnimatedPaletteNotifier, AppColors>((ref) {
  return AnimatedPaletteNotifier(ref);
});

class AnimatedPaletteNotifier extends StateNotifier<AppColors> {
  AnimatedPaletteNotifier(this._ref) : super(AppColors.fixed) {
    _init();
  }

  final Ref _ref;
  Timer? _debounceTimer;
  AppColors? _targetColors;
  AppColors _startColors = AppColors.fixed;
  DateTime? _animationStart;
  static const _duration = Duration(milliseconds: 1000);

  void _init() {
    _ref.listen(currentPaletteProvider, (previous, next) {
      if (previous == next) return;
      
      _startColors = state;
      _targetColors = next;
      _animationStart = DateTime.now();
      
      _debounceTimer?.cancel();
      _animate();
    });
  }

  void _animate() {
    if (_targetColors == null) return;
    
    final elapsed = DateTime.now().difference(_animationStart!);
    final t = (elapsed.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final eased = Curves.easeInOutCubic.transform(t);
    
    state = AppColors.lerp(_startColors, _targetColors!, eased);
    
    if (t < 1.0) {
      _debounceTimer = Timer(const Duration(milliseconds: 16), _animate);
    } else {
      state = _targetColors!;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
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

  factory AppColors.fromPalette(PaletteGenerator palette) {
    final dominant = palette.dominantColor?.color ?? Colors.grey;
    final hsl = HSLColor.fromColor(dominant);
    final baseHue = hsl.hue;
    final baseSat = (hsl.saturation * 0.6).clamp(0.15, 0.50);

    final elevated = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.7, 0.20).toColor();
    final accent = HSLColor.fromAHSL(1.0, baseHue, baseSat, 0.55).toColor();
    final gradientTop = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.8, 0.18).toColor();
    final gradientBottom = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.3, 0.03).toColor();
    final midBackground = Color.lerp(gradientTop, gradientBottom, 0.6)!;

    return AppColors._(
      background: midBackground,
      elevated: elevated,
      elevatedVariant: _darken(elevated, 0.05),
      elevatedHi: accent,
      elevatedProgressBar: accent.withValues(alpha: 0.5),
      outline: _lighten(elevated, 0.15),
      textPrimary: const Color(0xFFF9F8F8),
      textSecondary: const Color(0xB3F9F8F8),
      textTertiary: const Color(0x80F9F8F8),
      accent: accent,
      gradientTop: gradientTop,
      gradientBottom: gradientBottom,
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
      elevatedProgressBar: Color.lerp(a.elevatedProgressBar, b.elevatedProgressBar, t)!,
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

  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0)).toColor();
  }

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0)).toColor();
  }
}