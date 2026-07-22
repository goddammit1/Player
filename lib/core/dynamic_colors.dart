import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

@immutable
class DynamicPalette {
  const DynamicPalette({
    required this.primary,
    required this.elevated,
    required this.accent,
    required this.gradientTop,
    required this.gradientBottom,
  });

  final Color primary;
  final Color elevated;
  final Color accent;
  final Color gradientTop;
  final Color gradientBottom;

  // ── ArchiveTune + ViTune hybrid extraction ────────────────────────────
  // Возвращает null для серых / почти-серых обложек: у них нет надёжного
  // hue (HSL даёт hue = 0, то есть красный), поэтому вызывающий код должен
  // откатиться на фиксированную тему, а не выдумывать оттенок.
  static DynamicPalette? fromPalette(PaletteGenerator palette) {
    return _PaletteExtractor(palette).extract();
  }

  // ── Fallback: simplified from dominant ──────────────────────────────────
  factory DynamicPalette.fromDominant(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    final baseHue = hsl.hue;
    final baseSat = (hsl.saturation * 0.6).clamp(0.15, 0.50);

    final elevated = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.7, 0.20).toColor();
    final accent = HSLColor.fromAHSL(1.0, baseHue, baseSat, 0.55).toColor();
    final gradientTop = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.8, 0.18).toColor();
    final gradientBottom = HSLColor.fromAHSL(1.0, baseHue, baseSat * 0.3, 0.03).toColor();

    return DynamicPalette(
      primary: const Color(0xFFF9F8F8),
      elevated: elevated,
      accent: accent,
      gradientTop: gradientTop,
      gradientBottom: gradientBottom,
    );
  }

  static const empty = DynamicPalette(
    primary: Color(0xFFF9F8F8),
    elevated: Color(0xFF212124),
    accent: Color(0xFF747474),
    gradientTop: Color(0xFF161618),
    gradientBottom: Color(0xFF000000),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DynamicPalette &&
          primary == other.primary &&
          elevated == other.elevated &&
          accent == other.accent &&
          gradientTop == other.gradientTop &&
          gradientBottom == other.gradientBottom;

  @override
  int get hashCode => Object.hash(primary, elevated, accent, gradientTop, gradientBottom);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Hybrid: ArchiveTune extraction + ViTune HSL comfort + ViViMusic vibrancy check
// ═══════════════════════════════════════════════════════════════════════════

class _PaletteExtractor {
  final PaletteGenerator palette;

  _PaletteExtractor(this.palette);

  DynamicPalette? extract() {
    // 1. Collect swatches ArchiveTune-style (7 types, priority order)
    final allSwatches = [
      palette.vibrantColor,
      palette.lightVibrantColor,
      palette.darkVibrantColor,
      palette.dominantColor,
      palette.mutedColor,
      palette.darkMutedColor,
      palette.lightMutedColor,
    ].whereType<PaletteColor>().toList();

    // 2. Remove duplicates by RGB
    final seenRgb = <int>{};
    final uniqueSwatches = <PaletteColor>[];
    for (final swatch in allSwatches) {
      if (seenRgb.add(swatch.color.toARGB32())) {
        uniqueSwatches.add(swatch);
      }
    }

    // 3. Rank by weight (ArchiveTune: population * vibrancy_bonus)
    final ranked = uniqueSwatches.toList()
      ..sort((a, b) => _calculateWeight(b).compareTo(_calculateWeight(a)));

    // 4. Extract unique colors with vibrancy check (ViViMusic-style)
    final availableColors = <Color>[];

    for (final swatch in ranked) {
      final color = swatch.color;
      // ViViMusic: skip non-vibrant
      if (!_isVibrant(color)) continue;

      final hsv = _toHsv(color);
      final satFactor = hsv[1] > 0.3 ? 1.25 : 1.05;
      final enhanced = _enhanceVividness(color, satFactor);

      // ArchiveTune: uniqueness check
      if (!_isSimilarToAny(enhanced, availableColors)) {
        availableColors.add(enhanced);
      }
      if (availableColors.length >= 6) break;
    }

    // 5. Greyscale detection (ArchiveTune)
    final totalPopulation = allSwatches.fold<int>(0, (sum, s) => sum + s.population).clamp(1, 999999);
    final weightedSat = allSwatches.fold<double>(0.0, (sum, s) {
      final hsv = _toHsv(s.color);
      return sum + hsv[1] * s.population;
    }) / totalPopulation;

    final dominantColor = availableColors.firstOrNull ?? Colors.grey;
    final isGreyscale = weightedSat < 0.22 || _isNearGray(dominantColor);

    // Серая / почти-серая обложка → фиксированная тема (null наверх).
    if (isGreyscale) return null;

    // 6. Single-seed: pick the brightest vibrant color and build the whole
    //    palette from its hue. Accent + surfaces + gradient share one hue,
    //    so the Play button never clashes with the rest of the interface.
    final seed = _brightestSeed(availableColors, fallback: dominantColor);

    // Второй guard: даже если детектор выше промахнулся (JPEG-шум задрал
    // weightedSat), вымытый seed не даёт осмысленного оттенка — тоже fixed.
    if (_isNearGray(seed)) return null;

    return _buildMonochrome(seed);
  }

  // Pick the brightest (max HSV value) candidate as the single seed.
  Color _brightestSeed(List<Color> colors, {required Color fallback}) {
    if (colors.isEmpty) return fallback;
    return colors.reduce((a, b) => _toHsv(a)[2] >= _toHsv(b)[2] ? a : b);
  }

  // ── ViViMusic: vibrancy check before using color ───────────────────────
  bool _isVibrant(Color color) {
    final hsv = _toHsv(color);
    final saturation = hsv[1];
    final brightness = hsv[2];
    return saturation > 0.25 && brightness > 0.2 && brightness < 0.9;
  }

  // ── ArchiveTune: weight calculation ────────────────────────────────────
  double _calculateWeight(PaletteColor swatch) {
    final hsv = _toHsv(swatch.color);
    final saturation = hsv[1];
    final brightness = hsv[2];
    final vibrancyBonus = (saturation > 0.3 && brightness >= 0.2 && brightness <= 0.9) ? 1.3 : 1.0;
    return swatch.population * vibrancyBonus;
  }

  // ── ArchiveTune: vividness enhancement ─────────────────────────────────
  Color _enhanceVividness(Color color, double saturationFactor) {
    final hsv = _toHsv(color);
    hsv[1] = (hsv[1] * saturationFactor).clamp(0.0, 1.0);
    hsv[2] = (hsv[2] * 1.02).clamp(0.32, 0.88);
    return _fromHsv(hsv);
  }

  // ── ArchiveTune: similarity check ──────────────────────────────────────
  bool _isSimilarColor(Color a, Color b) {
    final hsv1 = _toHsv(a);
    final hsv2 = _toHsv(b);

    final hueDiffRaw = (hsv1[0] - hsv2[0]).abs();
    final hueDiff = math.min(hueDiffRaw, 360 - hueDiffRaw);
    final satDiff = (hsv1[1] - hsv2[1]).abs();
    final valDiff = (hsv1[2] - hsv2[2]).abs();

    if (hueDiff < 12 && satDiff < 0.12 && valDiff < 0.12) return true;

    const threshold = 28;
    final r1 = (a.r * 255).round();
    final g1 = (a.g * 255).round();
    final b1 = (a.b * 255).round();
    final r2 = (b.r * 255).round();
    final g2 = (b.g * 255).round();
    final b2 = (b.b * 255).round();

    return (r1 - r2).abs() < threshold &&
        (g1 - g2).abs() < threshold &&
        (b1 - b2).abs() < threshold;
  }

  bool _isSimilarToAny(Color color, List<Color> colors) {
    return colors.any((c) => _isSimilarColor(color, c));
  }

  // ── Single-seed monochrome palette ─────────────────────────
  // One hue for everything; roles differ only by saturation/lightness, so the
  // accent (Play button) stays in the same family as the background.
  DynamicPalette _buildMonochrome(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    final hue = hsl.hue;
    // Нижнюю границу не поднимаем: серый seed уже отсеян в extract(),
    // а тусклые (но цветные) обложки не должны получать фантомную насыщенность.
    final baseSat = hsl.saturation.clamp(0.05, 0.85);

    Color at(double sat, double light) => HSLColor.fromAHSL(
          1.0,
          hue,
          sat.clamp(0.0, 1.0),
          light.clamp(0.0, 1.0),
        ).toColor();

    // Accent: keep it as bright as possible while white icons on top still
    // meet the WCAG contrast target.
    final accent = _accentForHue(hue, baseSat * 0.9);

    return DynamicPalette(
      primary: const Color(0xFFF9F8F8),
      elevated: at(baseSat * 0.45, 0.20),
      accent: accent,
      gradientTop: at(baseSat * 0.50, 0.16),
      gradientBottom: at(baseSat * 0.35, 0.05),
    );
  }

  // Darken the accent hue until white-on-accent reaches [minContrast] (WCAG).
  // 4.5 is the AA target for normal text; drop to ~3.0 if you want the button
  // brighter and only need large-icon contrast.
  Color _accentForHue(
    double hue,
    double saturation, {
    Color on = Colors.white,
    double minContrast = 4.5,
    double maxLightness = 0.62,
    double minLightness = 0.30,
    double step = 0.02,
  }) {
    var light = maxLightness;
    var candidate = HSLColor.fromAHSL(1.0, hue, saturation, light).toColor();
    while (light > minLightness &&
        _contrastRatio(candidate, on) < minContrast) {
      light -= step;
      candidate = HSLColor.fromAHSL(1.0, hue, saturation, light).toColor();
    }
    return candidate;
  }

  // ── WCAG 2.x relative luminance + contrast ratio ───────────────
  double _relativeLuminance(Color c) {
    double lin(double channel) => channel <= 0.03928
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  }

  double _contrastRatio(Color a, Color b) {
    final la = _relativeLuminance(a);
    final lb = _relativeLuminance(b);
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  bool _isNearGray(Color color) {
    final hsv = _toHsv(color);
    return hsv[1] < 0.15 || hsv[2] < 0.08;
  }

  // ── HSV <-> HSL conversion (Flutter-compatible) ────────────────────────
  List<double> _toHsv(Color color) {
    final hsl = HSLColor.fromColor(color);
    final s = hsl.saturation;
    final l = hsl.lightness;
    final v = l + s * math.min(l, 1 - l);
    final sv = v == 0 ? 0.0 : 2 * (1 - l / v);
    return [hsl.hue, sv.clamp(0.0, 1.0), v.clamp(0.0, 1.0)];
  }

  Color _fromHsv(List<double> hsv) {
    final h = hsv[0];
    final s = hsv[1];
    final v = hsv[2];
    final l = v * (1 - s / 2);
    final sl = l == 0 || l == 1 ? 0.0 : (v - l) / math.min(l, 1 - l);
    return HSLColor.fromAHSL(1.0, h, sl.clamp(0.0, 1.0), l.clamp(0.0, 1.0)).toColor();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Provider
// ═══════════════════════════════════════════════════════════════════════════

// Провайдер dynamicPaletteProvider удалён: он нигде не использовался.
// Палитра темы строится в global_theme_provider.dart через
// AppColors.fromDynamicPalette(DynamicPalette.fromPalette(...)).
