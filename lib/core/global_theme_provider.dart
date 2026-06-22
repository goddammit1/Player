import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';

import 'providers.dart';

/// Провайдер анимированной палитры — используйте вместо currentPaletteProvider
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
    // Слушаем изменения текущей палитры
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

/// Мгновенная палитра (без анимации) — для внутреннего использования
final currentPaletteProvider = Provider<AppColors>((ref) {
  final mode = ref.watch(appThemeModeProvider);

  if (mode == AppThemeMode.fixed) {
    return AppColors.fixed;
  }

  final mediaItemAsync = ref.watch(_mediaItemProvider);
  final artworkUrl = mediaItemAsync.value?.artUri?.toString();

  if (artworkUrl == null || artworkUrl.isEmpty) {
    return AppColors.fixed;
  }

  final asyncPalette = ref.watch(dynamicPaletteProvider(artworkUrl));
  return asyncPalette.when(
    data: (p) => AppColors.fromDynamic(p),
    loading: () => AppColors.fixed,
    error: (_, _) => AppColors.fixed,
  );
});

final _mediaItemProvider = StreamProvider<MediaItem?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem;
});

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

  factory AppColors.fromDynamic(DynamicPalette palette) {
      final midBackground = Color.lerp(palette.gradientTop, palette.gradientBottom, 0.6)!;
      return AppColors._(
        background: midBackground,
        elevated: palette.elevated,
        elevatedVariant: _darken(palette.elevated, 0.05),

        elevatedHi: palette.accent,
        elevatedProgressBar: palette.accent.withValues(alpha: 0.5),
        outline: _lighten(palette.elevated, 0.15),
        textPrimary: const Color(0xFFF9F8F8),
        textSecondary: const Color(0xB3F9F8F8),
        textTertiary: const Color(0x80F9F8F8),
        accent: palette.accent,
        gradientTop: palette.gradientTop,
        gradientBottom: palette.gradientBottom,
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