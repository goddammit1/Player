import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart' show MemoryImage;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:player/core/providers/global_theme_provider.dart';
import 'package:player/core/providers/perceptual_colors.dart';

/// Контраст по WCAG через tone HCT (tone = L* в CIELAB).
double _contrast(Color a, Color b) => Contrast.ratioOfTones(
      Hct.fromInt(a.toARGB32()).tone,
      Hct.fromInt(b.toARGB32()).tone,
    );

Hct _hct(Color c) => Hct.fromInt(c.toARGB32());

int _argb(double hue, double chroma, double tone) =>
    Hct.from(hue, chroma, tone).toInt();

/// PNG 64×64, залитый [color].
Future<MemoryImage> _solidPng(Color color) async {
  final recorder = PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = color);
  final image = await recorder.endRecording().toImage(64, 64);
  final png = await image.toByteData(format: ImageByteFormat.png);
  image.dispose();
  return MemoryImage(png!.buffer.asUint8List());
}

/// PNG 64×64: верхние три четверти [main], нижняя четверть [other].
Future<MemoryImage> _twoColorPng(Color main, Color other) async {
  final recorder = PictureRecorder();
  Canvas(recorder)
    ..drawRect(const Rect.fromLTWH(0, 0, 64, 48), Paint()..color = main)
    ..drawRect(const Rect.fromLTWH(0, 48, 64, 16), Paint()..color = other);
  final image = await recorder.endRecording().toImage(64, 64);
  final png = await image.toByteData(format: ImageByteFormat.png);
  image.dispose();
  return MemoryImage(png!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Seed'ы по кругу оттенков плюс трудные случаи: серый, пастель,
  // почти чёрный, почти белый.
  final seeds = <String, int>{
    for (var hue = 0; hue < 360; hue += 30)
      'hue $hue': _argb(hue.toDouble(), 60, 50),
    'серый': 0xFF808080,
    'пастель': _argb(200, 12, 85),
    'почти чёрный': 0xFF0A0A0C,
    'почти белый': 0xFFF4F4F2,
  };

  group('buildPerceptualPalette: контраст и светлота', () {
    for (final entry in seeds.entries) {
      test(entry.key, () {
        final p = buildPerceptualPalette(entry.value, const []);

        // Текст на фоне — не ниже AA для обычного текста.
        expect(_contrast(p.textPrimary, p.gradientTop), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.textPrimary, p.gradientBottom),
            greaterThanOrEqualTo(4.5));
        // На elevatedHi рисуются белые иконки и подписи (кнопка Play,
        // кнопки диалогов, подсветка играющего трека).
        expect(_contrast(const Color(0xFFFFFFFF), p.elevatedHi),
            greaterThanOrEqualTo(4.5));
        expect(_contrast(p.textPrimary, p.elevatedHi),
            greaterThanOrEqualTo(4.5));
        // Акцент — цветные элементы поверх тёмного фона.
        expect(_contrast(p.accent, p.gradientTop), greaterThanOrEqualTo(3));
        // elevatedHi ещё и передний план: прогресс-бар, курсоры, рамки.
        // Против светлого верха градиента (t18) запас меньше 3:1 —
        // компромисс с белым текстом на той же заливке.
        expect(_contrast(p.elevatedHi, p.background), greaterThanOrEqualTo(3));
        expect(
            _contrast(p.elevatedHi, p.gradientBottom), greaterThanOrEqualTo(3));

        // Фон тёмный в узком коридоре, низ темнее верха.
        expect(_hct(p.gradientTop).tone, inInclusiveRange(12, 24));
        expect(_hct(p.gradientBottom).tone, lessThanOrEqualTo(10));

        expect(p.meshColors, hasLength(4));
      });
    }
  });

  group('buildPerceptualPalette: оттенок и насыщенность', () {
    test('оттенок акцента совпадает с оттенком seed', () {
      for (var hue = 0; hue < 360; hue += 30) {
        final p = buildPerceptualPalette(_argb(hue.toDouble(), 60, 50), const []);
        final diff = (_hct(p.accent).hue - hue).abs();
        expect(diff < 6 || diff > 354, isTrue, reason: 'hue $hue → $diff');
      }
    });

    test('серая обложка даёт нейтральную палитру без выдуманного цвета', () {
      final p = buildPerceptualPalette(0xFF808080, const []);
      expect(_hct(p.accent).chroma, lessThan(8));
      expect(_hct(p.elevatedHi).chroma, lessThan(8));
      expect(_hct(p.gradientTop).chroma, lessThan(8));
    });

    test('пастельный seed усиливается до заметного акцента', () {
      final p = buildPerceptualPalette(_argb(200, 12, 85), const []);
      // Ниже ~34 кнопка Play на tone 46 выглядит серой (замер на устройстве).
      expect(_hct(p.accent).chroma, greaterThanOrEqualTo(34));
      expect(_hct(p.elevatedHi).chroma, greaterThanOrEqualTo(34));
    });

    test('почти серый seed не превращается в яркий акцент', () {
      // Без плавного разгона chroma 8.5 скачком становилась бы 36.
      final p = buildPerceptualPalette(_argb(30, 8.5, 50), const []);
      expect(_hct(p.accent).chroma, lessThan(16));
    });

    test('кричащий seed приглушается', () {
      final p = buildPerceptualPalette(_argb(25, 110, 55), const []);
      expect(_hct(p.accent).chroma, lessThanOrEqualTo(49));
      expect(_hct(p.gradientTop).chroma, lessThanOrEqualTo(17));
    });

    test('тёмный жёлто-зелёный не попадает в «нелюбимые» цвета', () {
      final p = buildPerceptualPalette(_argb(100, 60, 45), const []);
      expect(DislikeAnalyzer.isDisliked(_hct(p.accent)), isFalse);
      expect(DislikeAnalyzer.isDisliked(_hct(p.elevatedHi)), isFalse);
      // Не серо-оливковый: насыщенность сохраняется, оттенок уходит
      // к ближайшей границе «нелюбимого» диапазона.
      expect(_hct(p.elevatedHi).chroma, greaterThanOrEqualTo(30));
      expect((_hct(p.elevatedHi).hue - 100).abs(), lessThan(15));
    });
  });

  test('жёлто-зелёные seed по всему диапазону не дают «нелюбимых» цветов', () {
    for (var hue = 80; hue <= 120; hue += 1) {
      for (final chroma in const [17.0, 20.0, 25.0, 33.0, 40.0, 55.0, 70.0]) {
        final seed = _argb(hue.toDouble(), chroma, 50);
        final p = buildPerceptualPalette(seed, [seed]);
        for (final c in [p.elevatedHi, p.accent, ...p.meshColors]) {
          expect(DislikeAnalyzer.isDisliked(_hct(c)), isFalse,
              reason: 'hue $hue chroma $chroma → ${_hct(c).hue}');
        }
      }
    }
  });

  group('buildPerceptualPalette: цвета для mesh', () {
    test('берутся из дополнительных seed с сохранением оттенков', () {
      final red = _argb(25, 60, 50);
      final blue = _argb(260, 60, 50);
      final p = buildPerceptualPalette(red, [red, blue]);

      final hues = p.meshColors.map((c) => _hct(c).hue).toList();
      expect(hues.any((h) => (h - 260).abs() < 8), isTrue, reason: '$hues');
    });

    test('недостающие цвета достраиваются, все тёмные', () {
      final p = buildPerceptualPalette(_argb(140, 50, 50), const []);
      expect(p.meshColors, hasLength(4));
      expect(p.meshColors.toSet(), hasLength(4));
      for (final c in p.meshColors) {
        expect(_contrast(const Color(0xFFFFFFFF), c), greaterThanOrEqualTo(4.5));
        // Темнее кнопок elevated (tone 22) с запасом: иначе они сливаются
        // с фоном (замер на устройстве).
        expect(_hct(c).tone, lessThanOrEqualTo(28.5));
      }
    });
  });

  group('extractPerceptualSeeds', () {
    test('главный цвет — преобладающий, второй попадает в mesh', () async {
      final red = 0xFFD03030;
      final blue = 0xFF3050D0;
      final pixels = [
        ...List.filled(700, red),
        ...List.filled(300, blue),
      ];

      final seeds = await extractPerceptualSeeds(pixels);

      expect(seeds, isNotNull);
      expect((Hct.fromInt(seeds!.seed).hue - Hct.fromInt(red).hue).abs(),
          lessThan(10));
      expect(
        seeds.meshSeeds
            .any((c) => (Hct.fromInt(c).hue - Hct.fromInt(blue).hue).abs() < 10),
        isTrue,
      );
    });

    test('чёрно-белая обложка не превращается в синюю', () async {
      final pixels = [
        ...List.filled(600, 0xFF101010),
        ...List.filled(400, 0xFFE0E0E0),
      ];

      final seeds = await extractPerceptualSeeds(pixels);

      expect(seeds, isNotNull);
      expect(Hct.fromInt(seeds!.seed).chroma, lessThan(5));
    });

    test('пустой список пикселей → null', () async {
      expect(await extractPerceptualSeeds(const []), isNull);
    });
  });

  group('perceptualPaletteFromImage', () {
    test('палитра строится по пикселям обложки', () async {
      final red = Color(_argb(25, 60, 50));
      final blue = Color(_argb(260, 60, 50));

      final palette =
          await perceptualPaletteFromImage(await _twoColorPng(red, blue));

      expect(palette, isNotNull);
      expect((_hct(palette!.accent).hue - 25).abs(), lessThan(8));
      expect(
        palette.meshColors.any((c) => (_hct(c).hue - 260).abs() < 8),
        isTrue,
      );
    });
  });

  group('perceptualPaletteFromImage: края', () {
    test('полностью прозрачная обложка → null', () async {
      expect(await perceptualPaletteFromImage(await _solidPng(const Color(0x00000000))),
          isNull);
    });

    test('ошибка декодирования пробрасывается', () async {
      final broken = MemoryImage(Uint8List.fromList([1, 2, 3, 4]));
      await expectLater(perceptualPaletteFromImage(broken), throwsA(anything));
    });
  });

  group('AppColors', () {
    test('равенство сравнивает mesh-цвета по значению, а не по ссылке', () {
      final seed = _argb(25, 60, 50);
      final a = AppColors.fromPerceptualPalette(
          buildPerceptualPalette(seed, const []));
      final b = AppColors.fromPerceptualPalette(
          buildPerceptualPalette(seed, const []));

      expect(identical(a.meshColors, b.meshColors), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('fromPerceptualPalette переносит роли палитры', () {
      final p = buildPerceptualPalette(_argb(25, 60, 50), const []);
      final colors = AppColors.fromPerceptualPalette(p);

      expect(colors.isDynamic, isTrue);
      expect(colors.accent, p.accent);
      expect(colors.elevatedHi, p.elevatedHi);
      expect(colors.gradientTop, p.gradientTop);
      expect(colors.meshColors, p.meshColors);
    });

    test('у fixed тоже четыре цвета mesh', () {
      expect(AppColors.fixed.meshColors, hasLength(4));
    });

    test('lerp переходит между цветами mesh поэлементно', () {
      final b = AppColors.fromPerceptualPalette(
        buildPerceptualPalette(_argb(25, 60, 50), const []),
      );

      expect(AppColors.lerp(AppColors.fixed, b, 0).meshColors,
          AppColors.fixed.meshColors);
      expect(AppColors.lerp(AppColors.fixed, b, 1).meshColors, b.meshColors);
      expect(AppColors.lerp(AppColors.fixed, b, 0.5), isNot(AppColors.fixed));
    });

    test('палитры с разными mesh-цветами не равны', () {
      final a = AppColors.fromPerceptualPalette(
        buildPerceptualPalette(_argb(25, 60, 50), [_argb(260, 60, 50)]),
      );
      final b = AppColors.fromPerceptualPalette(
        buildPerceptualPalette(_argb(25, 60, 50), [_argb(140, 60, 50)]),
      );
      expect(a, isNot(b));
    });
  });
}
