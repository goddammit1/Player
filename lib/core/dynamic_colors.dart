import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  factory DynamicPalette.fromPalette(PaletteGenerator palette) {
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

  DynamicPalette extract() {
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

    if (isGreyscale) {
      return _buildGreyscalePalette(allSwatches);
    }

    // 6. Generate up to 6 colors via hue shifts (ArchiveTune)
    final seed = dominantColor;
    final hueShifts = [25.0, -25.0, 55.0, -55.0, 120.0, -120.0, 180.0, 150.0, -150.0];
    final valueTargets = [0.82, 0.74, 0.68, 0.6, 0.86, 0.7];

    final baseCandidates = ([...availableColors, seed]).toSet().toList();
    var baseIndex = 0;
    var targetIndex = 0;

    while (availableColors.length < 6) {
      final baseColor = baseCandidates[baseIndex % baseCandidates.length];
      final hueShift = hueShifts[targetIndex % hueShifts.length];
      final valueTarget = valueTargets[availableColors.length % valueTargets.length];

      final derived = _tuneColor(
        _hueShift(baseColor, hueShift),
        saturationMin: 0.62,
        saturationBoost: 1.08,
        valueTarget: valueTarget,
        valueMin: 0.38,
        valueMax: 0.9,
      );

      if (!_isSimilarToAny(derived, availableColors)) {
        availableColors.add(derived);
      }

      baseIndex++;
      targetIndex++;
      if (baseIndex > 40) break;
    }

    if (availableColors.isEmpty) {
      availableColors.add(_tuneColor(
        Colors.grey,
        saturationMin: 0.62,
        saturationBoost: 1.08,
        valueTarget: 0.75,
        valueMin: 0.38,
        valueMax: 0.9,
      ));
    }

    return _buildFromColors(availableColors);
  }

  // ── Greyscale: ViTune-style greyscale with hue preservation ────────────
  DynamicPalette _buildGreyscalePalette(List<PaletteColor> swatches) {
    final baseSwatch = _swatchWithMaxPopulation(swatches);
    final baseHsv = _toHsv(baseSwatch.color);
    final baseBrightness = baseHsv.last;
    final baseHue = baseHsv[0]; // Preserve hue even in greyscale

    // ArchiveTune grey stops with slight hue tint
    final greyStops = [
      (baseBrightness * 1.2).clamp(0.06, 0.40),
      (baseBrightness * 0.9).clamp(0.04, 0.28),
      (baseBrightness * 0.6).clamp(0.02, 0.16),
      (baseBrightness * 1.4).clamp(0.08, 0.44),
    ];

    final colors = greyStops.map((v) {
      // ViTune: keep slight hue from original instead of pure grey
      final sat = baseHsv[1] < 0.15 ? 0.0 : 0.05;
      return HSLColor.fromAHSL(1.0, baseHue, sat, v).toColor();
    }).toList();

    return _buildFromColors(colors);
  }

  PaletteColor _swatchWithMaxPopulation(List<PaletteColor> swatches) {
    return swatches.reduce((a, b) => a.population > b.population ? a : b);
  }

  // ── Build final palette: ViTune HSL comfort + ArchiveTune richness ──────
  DynamicPalette _buildFromColors(List<Color> colors) {
    // ArchiveTune: use first 4 colors for different roles
    final top = colors[0];
    final accent = colors.length > 1 ? colors[1] : top;
    final mid = colors.length > 2 ? colors[2] : accent;
    final bottom = colors.length > 3 ? colors[3] : mid;

    // ViTune: HSL comfort limits for dark theme player
    return DynamicPalette(
      primary: const Color(0xFFF9F8F8),
      elevated: _hslComfort(mid, saturationMax: 0.4, lightness: 0.20),
      accent: _hslComfort(accent, saturationMax: 0.5, lightness: 0.55),
      gradientTop: _hslComfort(top, saturationMax: 0.4, lightness: 0.18),
      gradientBottom: _hslComfort(bottom, saturationMax: 0.2, lightness: 0.05),
    );
  }

  // ── ViTune-style HSL comfort (predictable, controlled) ─────────────────
  Color _hslComfort(Color color, {required double saturationMax, required double lightness}) {
    final hsl = HSLColor.fromColor(color);
    return HSLColor.fromAHSL(
      1.0,
      hsl.hue,
      hsl.saturation.clamp(0.15, saturationMax),
      lightness.clamp(0.03, 0.58),
    ).toColor();
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

  Color _hueShift(Color color, double degrees) {
    final hsv = _toHsv(color);
    hsv[0] = ((hsv[0] + degrees) % 360 + 360) % 360;
    return _fromHsv(hsv);
  }

  Color _tuneColor(
    Color color, {
    required double saturationMin,
    required double saturationBoost,
    required double valueTarget,
    required double valueMin,
    required double valueMax,
  }) {
    final hsv = _toHsv(color);
    hsv[1] = math.max(hsv[1], saturationMin) * saturationBoost;
    hsv[1] = hsv[1].clamp(0.0, 1.0);
    hsv[2] = (hsv[2] * 0.85 + valueTarget * 0.15).clamp(valueMin, valueMax);
    return _fromHsv(hsv);
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

final dynamicPaletteProvider =
    FutureProvider.family<DynamicPalette, String>((ref, imageUrl) async {
  if (imageUrl.isEmpty) {
    return DynamicPalette.empty;
  }

  try {
    final palette = await PaletteGenerator.fromImageProvider(
      NetworkImage(imageUrl),
      maximumColorCount: 32,
      timeout: const Duration(seconds: 5),
    );

    return DynamicPalette.fromPalette(palette);
  } catch (e) {
    debugPrint('[DynamicPalette] Failed: $e');
    return DynamicPalette.empty;
  }
});