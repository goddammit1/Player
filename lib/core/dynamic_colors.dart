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

  factory DynamicPalette.fromDominant(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);

    final baseHue = hsl.hue;
    // БОЛЬШЕ насыщенности — до 50%
    final baseSat = (hsl.saturation * 0.6).clamp(0.15, 0.50);

    // Elevated: для обычных кнопок
    final elevated = HSLColor.fromAHSL(
      1.0, baseHue, baseSat * 0.7, 0.20,
    ).toColor();

    // Accent: САМЫЙ ЯРКИЙ — для Play кнопки
    final accent = HSLColor.fromAHSL(
      1.0, baseHue, baseSat, 0.55,
    ).toColor();

    // Градиент: сверху — насыщенный, снизу — темный
    final gradientTop = HSLColor.fromAHSL(
      1.0, baseHue, baseSat * 0.8, 0.18,
    ).toColor();

    final gradientBottom = HSLColor.fromAHSL(
      1.0, baseHue, baseSat * 0.3, 0.03,
    ).toColor();

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

final dynamicPaletteProvider =
    FutureProvider.family<DynamicPalette, String>((ref, imageUrl) async {
  if (imageUrl.isEmpty) {
    return DynamicPalette.empty;
  }

  try {
    final palette = await PaletteGenerator.fromImageProvider(
      NetworkImage(imageUrl),
      maximumColorCount: 24, // Больше цветов
      timeout: const Duration(seconds: 5),
    );

    final color = _selectBestColor(palette);
    return DynamicPalette.fromDominant(color);
  } catch (e) {
    debugPrint('[DynamicColors] Failed: $e');
    return DynamicPalette.empty;
  }
});

/// ВЫБИРАЕМ ЦВЕТ, КОТОРЫЙ БЛИЖЕ ВСЕГО К ДОМИНАНТНОМУ ПО HUE
Color _selectBestColor(PaletteGenerator palette) {
  final colors = palette.colors.toList();
  if (colors.length < 3) return palette.dominantColor?.color ?? Colors.grey;

  // Группируем по hue, ищем самую большую группу с хорошей saturation
  final hueBuckets = <int, List<Color>>{};
  
  for (final c in colors) {
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.15 || hsl.lightness < 0.1) continue;
    
    final bucket = (hsl.hue / 30).floor() * 30; // 12 секторов
    hueBuckets.putIfAbsent(bucket, () => []).add(c);
  }

  // Выбираем сектор с наибольшим количеством цветов
  final bestBucket = hueBuckets.entries
    .fold<MapEntry<int, List<Color>>?>(null, (best, entry) {
      if (best == null) return entry;
      return entry.value.length > best.value.length ? entry : best;
    });

  if (bestBucket == null) return palette.dominantColor?.color ?? Colors.grey;

  // Берём средний цвет из сектора
  final avgH = bestBucket.value
    .map((c) => HSLColor.fromColor(c).hue)
    .reduce((a, b) => a + b) / bestBucket.value.length;
  final avgS = bestBucket.value
    .map((c) => HSLColor.fromColor(c).saturation)
    .reduce((a, b) => a + b) / bestBucket.value.length;
  final avgL = bestBucket.value
    .map((c) => HSLColor.fromColor(c).lightness)
    .reduce((a, b) => a + b) / bestBucket.value.length;

  return HSLColor.fromAHSL(1.0, avgH, avgS.clamp(0.15, 0.50), avgL.clamp(0.15, 0.6)).toColor();
}