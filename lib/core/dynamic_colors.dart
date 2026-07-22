import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Domain model — single seed, hue never changes
// ═══════════════════════════════════════════════════════════════════════════

@immutable
class DynamicPalette {
  const DynamicPalette({
    required this.seed,
    required this.primary,
    required this.elevated,
    required this.accent,
    required this.gradientTop,
    required this.gradientBottom,
  });

  /// The original colour extracted from the artwork.
  /// Its hue is preserved exactly in all derived colours.
  final Color seed;

  /// Near-white text.
  final Color primary;

  /// Dark surface.
  final Color elevated;

  /// Accent (Play button). Same hue as seed, adjusted for WCAG only.
  final Color accent;

  final Color gradientTop;
  final Color gradientBottom;

  static const empty = DynamicPalette(
    seed: Color(0xFF747474),
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
          seed == other.seed &&
          primary == other.primary &&
          elevated == other.elevated &&
          accent == other.accent &&
          gradientTop == other.gradientTop &&
          gradientBottom == other.gradientBottom;

  @override
  int get hashCode => Object.hash(seed, primary, elevated, accent, gradientTop, gradientBottom);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Role configuration
// ═══════════════════════════════════════════════════════════════════════════

@immutable
class PaletteRole {
  const PaletteRole({
    required this.targetSaturation,
    required this.targetLightness,
    this.minContrast,
    this.contrastAgainst,
    this.lightnessStep = 0.02,
    this.lightnessMin = 0.05,
    this.lightnessMax = 0.95,
  });

  final double targetSaturation;
  final double targetLightness;
  final double? minContrast;
  final Color? contrastAgainst;
  final double lightnessStep;
  final double lightnessMin;
  final double lightnessMax;
}

@immutable
class PaletteRoles {
  const PaletteRoles({
    required this.primary,
    required this.elevated,
    required this.accent,
    required this.gradientTop,
    required this.gradientBottom,
  });

  final PaletteRole primary;
  final PaletteRole elevated;
  final PaletteRole accent;
  final PaletteRole gradientTop;
  final PaletteRole gradientBottom;
}

class _DefaultRoles implements PaletteRoles {
  const _DefaultRoles();

  @override
  PaletteRole get primary => const PaletteRole(
        targetSaturation: 0.0,
        targetLightness: 0.97,
      );

  @override
  PaletteRole get elevated => const PaletteRole(
        targetSaturation: 0.40,
        targetLightness: 0.18,
        minContrast: 4.5,
        contrastAgainst: Color(0xFFF9F8F8),
        lightnessStep: 0.02,
        lightnessMin: 0.05,
        lightnessMax: 0.30,
      );

  @override
  PaletteRole get accent => const PaletteRole(
        targetSaturation: 0.75,
        targetLightness: 0.55,
        minContrast: 4.5,
        contrastAgainst: Color(0xFFF9F8F8),
        lightnessStep: 0.02,
        lightnessMin: 0.40,
        lightnessMax: 0.5,
      );

  @override
  PaletteRole get gradientTop => const PaletteRole(
        targetSaturation: 0.45,
        targetLightness: 0.14,
      );

  @override
  PaletteRole get gradientBottom => const PaletteRole(
        targetSaturation: 0.30,
        targetLightness: 0.03,
      );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Single-seed extractor
//  Strategy: most frequent non-monochrome colour, hue locked.
// ═══════════════════════════════════════════════════════════════════════════

class PaletteExtractor {
  PaletteExtractor({
    this.minSaturationLight = 0.08,   // value > 0.80 (pastels)
    this.minSaturationMedium = 0.12,  // value > 0.50
    this.minSaturationDark = 0.18,    // value <= 0.50
    this.enhanceSaturationFactor = 3.0,
    this.greyscaleSaturationThreshold = 0.15,
    this.roles = const _DefaultRoles(),
  });

  // --- Colourfulness thresholds (adaptive by brightness) ---
  // Lower = more colours pass, but risk of noisy hue.
  // These are intentionally low: we trust population over saturation.

  final double minSaturationLight;
  final double minSaturationMedium;
  final double minSaturationDark;

  // --- Enhancement ---

  /// Gentle boost. We do NOT want to change the character of the colour,
  /// just nudge it slightly more vivid.
  final double enhanceSaturationFactor;

  // --- Hard greyscale guard ---

  /// Weighted saturation below which the cover is truly greyscale.
  final double greyscaleSaturationThreshold;

  // --- Roles ---

  final PaletteRoles roles;

  // --- Public API ---

  DynamicPalette? fromPalette(PaletteGenerator palette) {
    return _extract(palette);
  }

  DynamicPalette? fromDominant(Color dominant) {
    if (_isNearGray(dominant)) return null;
    return _buildFromSeed(dominant);
  }

  // --- Core extraction ---

  DynamicPalette? _extract(PaletteGenerator palette) {
    final allSwatches = [
      palette.vibrantColor,
      palette.lightVibrantColor,
      palette.darkVibrantColor,
      palette.dominantColor,
      palette.mutedColor,
      palette.darkMutedColor,
      palette.lightMutedColor,
    ].whereType<PaletteColor>().toList();

    if (allSwatches.isEmpty) return null;

    final totalPopulation = math.max(
      1,
      allSwatches.fold<int>(0, (sum, s) => sum + s.population),
    );

    // ── 1. Filter: non-monochrome colours ────────────────────────────────
    // A colour is "non-monochrome" if it has enough saturation for its
    // brightness level. This catches pastels (light pink) that strict
    // thresholds would miss.
    final nonMono = allSwatches
        .where((s) => _isNonMonochrome(s.color))
        .toList();

    // ── 2. Hard greyscale guard ──────────────────────────────────────────
    if (nonMono.isEmpty) {
      final weightedSat = allSwatches.fold<double>(0.0, (sum, s) {
        final hsv = _toHsv(s.color);
        return sum + hsv.saturation * s.population;
      }) / totalPopulation;

      if (weightedSat < greyscaleSaturationThreshold) return null;

      // Last resort: most saturated of all
      final mostSat = _mostSaturated(allSwatches);
      if (_isNearGray(mostSat.color)) return null;
      return _buildFromSeed(_enhance(mostSat.color));
    }

    // ── 3. Pick seed: most frequent non-monochrome ───────────────────────
    // Sort by population (descending). The first one is our seed.
    nonMono.sort((a, b) => b.population.compareTo(a.population));
    final seed = _enhance(nonMono.first.color);

    return _buildFromSeed(seed);
  }

  // --- Helpers ---

  PaletteColor _mostSaturated(List<PaletteColor> swatches) {
    return swatches.reduce((a, b) {
      final sa = _toHsv(a.color).saturation;
      final sb = _toHsv(b.color).saturation;
      return sa >= sb ? a : b;
    });
  }

  // --- Non-monochrome check (adaptive) ---

  bool _isNonMonochrome(Color color) {
    final hsv = _toHsv(color);
    final minSat = hsv.value > 0.80
        ? minSaturationLight
        : hsv.value > 0.50
            ? minSaturationMedium
            : minSaturationDark;
    return hsv.saturation >= minSat && hsv.value > 0.05;
  }

  // --- Enhancement (gentle, preserves character) ---

  Color _enhance(Color color) {
    final hsv = _toHsv(color);
    final newSat = (hsv.saturation * enhanceSaturationFactor).clamp(0.0, 1.0);
    return _fromHsv(_HsvColor(hsv.hue, newSat, hsv.value));
  }

  // --- Palette builder: hue locked, only lightness/saturation vary ---

  DynamicPalette _buildFromSeed(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    final hue = hsl.hue;
    final seedSat = hsl.saturation;

    Color resolve(PaletteRole role) {
      // targetSaturation is a fraction of the seed's saturation.
      // e.g. seedSat=0.30 (pastel pink), role.targetSaturation=0.85
      // → resultSat=0.255 (still pastel, not neon)
      final sat = (seedSat * role.targetSaturation).clamp(0.0, 1.0);
      var light = role.targetLightness.clamp(role.lightnessMin, role.lightnessMax);
      var candidate = HSLColor.fromAHSL(1.0, hue, sat, light).toColor();

      // WCAG: adjust ONLY lightness, never hue or saturation direction.
      final targetContrast = role.minContrast;
      final against = role.contrastAgainst;
      if (targetContrast != null && against != null) {
        final currentContrast = _contrastRatio(candidate, against);
        if (currentContrast < targetContrast) {
          // Need more contrast: for dark surfaces darken,
          // for light surfaces lighten. Since our UI is dark-themed,
          // we usually need to darken for white text.
          final needsDarken = light > 0.5;
          if (needsDarken) {
            while (light < role.lightnessMax - 0.001 &&
                _contrastRatio(candidate, against) < targetContrast) {
              light += role.lightnessStep;
              candidate = HSLColor.fromAHSL(1.0, hue, sat, light).toColor();
            }
          } else {
            while (light > role.lightnessMin + 0.001 &&
                _contrastRatio(candidate, against) < targetContrast) {
              light -= role.lightnessStep;
              candidate = HSLColor.fromAHSL(1.0, hue, sat, light).toColor();
            }
          }
        }
      }

      return candidate;
    }

    return DynamicPalette(
      seed: seed,
      primary: resolve(roles.primary),
      elevated: resolve(roles.elevated),
      accent: resolve(roles.accent),
      gradientTop: resolve(roles.gradientTop),
      gradientBottom: resolve(roles.gradientBottom),
    );
  }

  // --- WCAG 2.x ---

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

  // --- Grey detection ---

  bool _isNearGray(Color color) {
    final hsv = _toHsv(color);
    return hsv.saturation < 0.12 || hsv.value < 0.05;
  }

  // --- HSV helpers ---

  _HsvColor _toHsv(Color color) {
    final hsv = HSVColor.fromColor(color);
    return _HsvColor(hsv.hue, hsv.saturation, hsv.value);
  }

  Color _fromHsv(_HsvColor hsv) {
    return HSVColor.fromAHSV(1.0, hsv.hue, hsv.saturation, hsv.value).toColor();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Immutable HSV triple
// ═══════════════════════════════════════════════════════════════════════════

@immutable
class _HsvColor {
  const _HsvColor(this.hue, this.saturation, this.value);

  final double hue;
  final double saturation;
  final double value;
}