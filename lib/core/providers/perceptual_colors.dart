import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Perceptual-палитра: роли задаются через tone HCT, а не через HSL-яркость.
//  Tone совпадает с L* в CIELAB, поэтому контраст между ролями определяется
//  разницей tone и не зависит от оттенка обложки. Классический экстрактор
//  (dynamic_colors.dart) остаётся без изменений для темы Classic.
// ═══════════════════════════════════════════════════════════════════════════

/// Сторона квадрата, до которого уменьшается обложка перед квантизацией.
/// 112² ≈ 12.5k пикселей: цветовой состав сохраняется, квантизация быстрая.
const _sampleSize = 112;
const _maxQuantizedColors = 128;
const _loadTimeout = Duration(seconds: 5);

/// Полупрозрачные пиксели ниже этой непрозрачности в статистику не идут.
const _minAlpha = 128;

/// Число цветов для mesh-фона страницы плеера.
const meshColorCount = 4;

/// Ниже этой насыщенности обложка считается серой: цвет не выдумываем.
const _neutralChroma = 8.0;

/// Насыщенность акцентов: пастель усиливается, кричащие цвета приглушаются.
const _accentMinChroma = 36.0;
const _accentRampEnd = 12.0;
const _accentMaxChroma = 48.0;

/// «Нелюбимый» диапазон оттенков DislikeAnalyzer (тёмный жёлто-зелёный).
const _dislikedHueMin = 90;
const _dislikedHueMax = 111;
const _dislikedMaxSteps = 5;

/// Насыщенность, ниже которой тёмный жёлто-зелёный не выглядит болотным
/// (порог DislikeAnalyzer); запасной вариант, если сдвиг оттенка не помог.
const _dislikedMaxChroma = 16.0;

/// Метка «Score не нашёл цветного кандидата»: у настоящих пикселей alpha = FF.
const _noScoredColor = 0x00000000;

// Tone ролей. elevatedHi 46 — светлота той же ступени, что 0x747474 у Fixed:
// на нём рисуются белые иконки и подписи (кнопка Play, кнопки диалогов,
// подсветка играющего трека), контраст с белым ≥ 4.5:1.
const _toneTextPrimary = 96.0;
const _toneAccent = 75.0;
const _toneElevatedHi = 46.0;
const _toneOutline = 30.0;
const _toneElevatedVariant = 26.0;
const _toneElevated = 22.0;
const _toneGradientTop = 18.0;
const _toneBackground = 11.0;
const _toneGradientBottom = 6.0;

// На 8 ниже первоначальных: вместе с затемнением низа в шейдере кнопки
// elevated (tone 22) не сливаются с фоном (проверено на устройстве).
const _meshTones = [22.0, 14.0, 28.0, 18.0];

/// Сдвиг оттенка для mesh-цветов, которых не хватило среди цветов обложки.
const _meshHueShifts = [0.0, 30.0, -30.0, 60.0];

/// Роли перцептивной палитры. Переводится в [AppColors] через
/// `AppColors.fromPerceptualPalette`.
@immutable
class PerceptualPalette {
  const PerceptualPalette({
    required this.background,
    required this.elevated,
    required this.elevatedVariant,
    required this.elevatedHi,
    required this.outline,
    required this.textPrimary,
    required this.accent,
    required this.gradientTop,
    required this.gradientBottom,
    required this.meshColors,
  });

  final Color background;
  final Color elevated;
  final Color elevatedVariant;

  /// Заливка под белым текстом и иконками.
  final Color elevatedHi;
  final Color outline;
  final Color textPrimary;

  /// Цветные элементы поверх тёмного фона: переключатели, индикаторы.
  final Color accent;
  final Color gradientTop;
  final Color gradientBottom;

  /// [meshColorCount] тёмных цветов для mesh-фона плеера.
  final List<Color> meshColors;
}

/// Главный цвет обложки и цвета для mesh (первый из них совпадает с главным).
@immutable
class PerceptualSeeds {
  const PerceptualSeeds({required this.seed, required this.meshSeeds});

  final int seed;
  final List<int> meshSeeds;
}

/// Строит палитру из главного цвета обложки [seedArgb] и дополнительных
/// цветов [meshSeeds] (от лучшего к худшему по Score).
PerceptualPalette buildPerceptualPalette(int seedArgb, List<int> meshSeeds) {
  final seed = Hct.fromInt(seedArgb);
  final hue = seed.hue;
  final chroma = seed.chroma;

  Color tone(double tone, double maxChroma) =>
      _color(Hct.from(hue, math.min(chroma, maxChroma), tone));

  final accentChroma = _accentChroma(chroma);

  return PerceptualPalette(
    background: tone(_toneBackground, 12),
    elevated: tone(_toneElevated, 14),
    elevatedVariant: tone(_toneElevatedVariant, 14),
    elevatedHi: _color(_likable(Hct.from(hue, accentChroma, _toneElevatedHi))),
    outline: tone(_toneOutline, 10),
    textPrimary: tone(_toneTextPrimary, 6),
    // На tone 75 «нелюбимых» цветов не бывает (порог DislikeAnalyzer — 65).
    accent: _color(Hct.from(hue, accentChroma, _toneAccent)),
    gradientTop: tone(_toneGradientTop, 16),
    gradientBottom: tone(_toneGradientBottom, 8),
    meshColors: List.unmodifiable(_meshColors(seed, meshSeeds)),
  );
}

List<Color> _meshColors(Hct seed, List<int> meshSeeds) {
  return List.generate(meshColorCount, (i) {
    final source = i < meshSeeds.length ? Hct.fromInt(meshSeeds[i]) : null;
    final hue = source?.hue ??
        MathUtils.sanitizeDegreesDouble(seed.hue + _meshHueShifts[i]);
    final chroma = (source ?? seed).chroma;
    final meshChroma = chroma < _neutralChroma ? chroma : chroma.clamp(16.0, 40.0);
    return _color(_likable(Hct.from(hue, meshChroma, _meshTones[i])));
  });
}

/// Слабо окрашенная обложка разгоняется до [_accentMinChroma] плавно
/// на отрезке [_neutralChroma]…[_accentRampEnd], без скачка на границе
/// серого.
double _accentChroma(double chroma) {
  if (chroma < _neutralChroma) return chroma;
  final ramp = ((chroma - _neutralChroma) / (_accentRampEnd - _neutralChroma))
      .clamp(0.0, 1.0);
  final minChroma = chroma + (_accentMinChroma - chroma) * ramp;
  return chroma.clamp(minChroma, _accentMaxChroma);
}

/// Тёмный насыщенный жёлто-зелёный выглядит болотным. Оттенок сдвигается к
/// ближайшей границе «нелюбимого» диапазона: приглушение давало серо-оливковый,
/// а `DislikeAnalyzer.fixIfDisliked` поднял бы tone и сломал контраст.
Hct _likable(Hct hct) {
  if (!DislikeAnalyzer.isDisliked(hct)) return hct;
  final down = hct.hue - _dislikedHueMin <= _dislikedHueMax - hct.hue;
  // Подгонка под гамму сдвигает итоговый hue на доли градуса, поэтому
  // отступаем от границы, пока цвет не выйдет из диапазона.
  for (var step = 1; step <= _dislikedMaxSteps; step++) {
    final hue = down ? _dislikedHueMin - step : _dislikedHueMax + step;
    // Проверяем уже 8-битный цвет: округление тоже сдвигает hue.
    final shifted = Hct.fromInt(Hct.from(hue.toDouble(), hct.chroma, hct.tone).toInt());
    if (!DislikeAnalyzer.isDisliked(shifted)) return shifted;
  }
  return Hct.from(hct.hue, _dislikedMaxChroma, hct.tone);
}

Color _color(Hct hct) => Color(hct.toInt());

/// Квантизация пикселей (Celebi) и выбор цветов (Score) по методике
/// Material You. Возвращает `null`, если пикселей нет.
Future<PerceptualSeeds?> extractPerceptualSeeds(List<int> argbPixels) async {
  if (argbPixels.isEmpty) return null;

  final result =
      await QuantizerCelebi().quantize(argbPixels, _maxQuantizedColors);
  final counts = result.colorToCount;
  if (counts.isEmpty) return null;

  final scored = Score.score(
    counts,
    desired: meshColorCount,
    fallbackColorARGB: _noScoredColor,
  );
  if (scored.first == _noScoredColor) {
    // Цветных кандидатов нет (ч/б обложка). Score подставил бы синий
    // Google, вместо него берём преобладающий серый.
    final dominant =
        counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return PerceptualSeeds(seed: dominant, meshSeeds: const []);
  }
  return PerceptualSeeds(seed: scored.first, meshSeeds: scored);
}

/// Палитра по обложке; `null`, если обложка пустая или полностью прозрачная.
Future<PerceptualPalette?> perceptualPaletteFromImage(
  ImageProvider provider,
) async {
  final pixels = await _loadArgbPixels(provider);
  // Квантизация ~65 мс синхронного счёта на телефоне: в фоновом изоляте,
  // иначе смена трека подлагивает (замер в фазе 6 плана).
  final seeds = await Isolate.run(() => extractPerceptualSeeds(pixels));
  if (seeds == null) return null;
  return buildPerceptualPalette(seeds.seed, seeds.meshSeeds);
}

/// Декодирует обложку не больше [_sampleSize]² и возвращает в ARGB пиксели
/// с непрозрачностью от [_minAlpha].
Future<List<int>> _loadArgbPixels(ImageProvider provider) async {
  final stream = ResizeImage(
    provider,
    width: _sampleSize,
    height: _sampleSize,
    policy: ResizeImagePolicy.fit,
  ).resolve(ImageConfiguration.empty);
  final completer = Completer<ui.Image>();
  final listener = ImageStreamListener(
    (info, _) {
      // Анимированная обложка присылает кадры повторно, нужен только первый.
      if (!completer.isCompleted) completer.complete(info.image.clone());
      info.dispose();
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  stream.addListener(listener);

  final ui.Image image;
  try {
    image = await completer.future.timeout(_loadTimeout);
  } finally {
    stream.removeListener(listener);
  }

  try {
    // Straight, а не premultiplied: у полупрозрачных пикселей цвет не темнеет.
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return const [];
    return _rgbaToOpaqueArgb(data);
  } finally {
    image.dispose();
  }
}

List<int> _rgbaToOpaqueArgb(ByteData rgba) {
  final pixels = <int>[];
  for (var i = 0; i + 3 < rgba.lengthInBytes; i += 4) {
    if (rgba.getUint8(i + 3) < _minAlpha) continue;
    pixels.add(0xFF000000 |
        (rgba.getUint8(i) << 16) |
        (rgba.getUint8(i + 1) << 8) |
        rgba.getUint8(i + 2));
  }
  return pixels;
}
