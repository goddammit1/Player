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

    // 4. Two-tier color collection.
    //    Сначала строгий отбор (яркие, насыщенные цвета). Если обложка
    //    приглушённая и строгий проход пуст — повторяем с relaxed-порогом,
    //    чтобы тусклый, но реально присутствующий цвет всё же попал в тему.
    var availableColors = _collectColors(ranked, minSaturation: 0.25);
    if (availableColors.isEmpty) {
      availableColors = _collectColors(ranked, minSaturation: _greyFloor);
    }

    // 5. Нет ни одного цвета выше grey-floor → обложка реально серая,
    //    откатываемся на фиксированную тему (null наверх). weightedSat как
    //    критерий убран: усреднение по площади топило мелкие явные акценты.
    if (availableColors.isEmpty) return null;

    // 6. Single-seed: берём самый насыщенный («заметный») цвет и строим всю
    //    палитру из его hue. Accent + поверхности + градиент в одной гамме,
    //    поэтому кнопка Play не конфликтует с остальным интерфейсом.
    final seed = _mostColorfulSeed(availableColors);

    // Финальная страховка: если даже выбранный seed по факту серый — fixed.
    if (_isNearGray(seed)) return null;

    return _buildMonochrome(seed);
  }

  // Grey-floor: ниже этой насыщенности цвет считаем нейтральным (серым).
  static const double _greyFloor = 0.12;

  // Собирает до 6 уникальных цветов с насыщенностью выше [minSaturation],
  // усиливая их живость (ArchiveTune-style).
  List<Color> _collectColors(
    List<PaletteColor> ranked, {
    required double minSaturation,
  }) {
    final colors = <Color>[];
    for (final swatch in ranked) {
      final color = swatch.color;
      final hsv = _toHsv(color);
      // Пропускаем нейтральные и пере/недо-экспонированные swatch'и.
      if (hsv[1] <= minSaturation || hsv[2] <= 0.2 || hsv[2] >= 0.9) continue;

      final satFactor = hsv[1] > 0.3 ? 1.25 : 1.05;
      final enhanced = _enhanceVividness(color, satFactor);

      if (!_isSimilarToAny(enhanced, colors)) {
        colors.add(enhanced);
      }
      if (colors.length >= 6) break;
    }
    return colors;
  }

  // Самый насыщенный кандидат — визуально самый «цепляющий».
  Color _mostColorfulSeed(List<Color> colors) {
    return colors.reduce((a, b) => _toHsv(a)[1] >= _toHsv(b)[1] ? a : b);
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

    // elevatedHi (accent, кнопка Play) → контраст к белому >= 8:1.
    // elevated (поверхности)          → контраст к белому >= 12:1.
    // Lightness как в устраивавшей версии; поднимаем только насыщенность,
    // и то мягким floor'ом — «тускло» было про сочность, не про яркость.
    final accentSat = math.max(baseSat, 0.45);
    final elevatedSat = math.max(baseSat * 0.6, 0.28);
    final accent = _darkenToContrast(hue, accentSat, targetRatio: 8.0);
    final elevated = _darkenToContrast(hue, elevatedSat, targetRatio: 12.0);

    // Фон/градиент: floor насыщенности + лёгкий подъём lightness. На очень
    // тёмном фоне (L 0.16/0.05) сатурация перцептивно не видна, поэтому
    // одной насыщенности мало — чуть выводим фон из «мёртвой» зоны,
    // оставляя его тёмным. Регуляторы: floor'ы 0.30/0.22 и L 0.20/0.08.
    final gradientTopSat = math.max(baseSat * 0.50, 0.30);
    final gradientBottomSat = math.max(baseSat * 0.35, 0.22);

    return DynamicPalette(
      primary: const Color(0xFFF9F8F8),
      elevated: elevated,
      accent: accent,
      gradientTop: at(gradientTopSat, 0.20),
      gradientBottom: at(gradientBottomSat, 0.08),
    );
  }

  // Затемняет цвет заданного hue/saturation, пока контраст к белому не
  // достигнет [targetRatio] (WCAG 2.x). Saturation фиксирована — без
  // докрутки при затемнении, иначе цвет уходит в кислотный перебор.
  Color _darkenToContrast(
    double hue,
    double saturation, {
    required double targetRatio,
    Color on = Colors.white,
    double maxLightness = 0.62,
    double minLightness = 0.05,
    double step = 0.01,
  }) {
    var light = maxLightness;
    var candidate = HSLColor.fromAHSL(1.0, hue, saturation, light).toColor();
    while (light > minLightness &&
        _contrastRatio(candidate, on) < targetRatio) {
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
    // Согласовано с _greyFloor: seed, прошедший relaxed-отбор (>0.12),
    // не должен тут же отсеиваться порогом 0.15 — иначе тусклые, но реально
    // присутствующие цвета всё равно уходили бы в fixed.
    return hsv[1] < _greyFloor || hsv[2] < 0.08;
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
