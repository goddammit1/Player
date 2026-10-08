import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers/color_space.dart';
import 'package:player/core/providers/global_theme_provider.dart';
import 'package:player/core/providers/perceptual_colors.dart';

double _chroma(Color c) {
  final lab = toOklab(c);
  return math.sqrt(lab.a * lab.a + lab.b * lab.b);
}

/// Оттенок OKLCh в градусах, [0, 360).
double _hue(Color c) {
  final lab = toOklab(c);
  return math.atan2(lab.b, lab.a) * 180 / math.pi % 360;
}

/// Угловое расстояние между оттенками, [0, 180].
double _hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  const blue = Color(0xFF1E5BFF);
  const orange = Color(0xFFFF8A1E);

  group('toOklab / fromOklab', () {
    test('белый и чёрный попадают в L = 1 и L = 0 без оттенка', () {
      final white = toOklab(const Color(0xFFFFFFFF));
      final black = toOklab(const Color(0xFF000000));

      expect(white.l, closeTo(1, 1e-4));
      expect(white.a, closeTo(0, 1e-4));
      expect(white.b, closeTo(0, 1e-4));
      expect(black.l, closeTo(0, 1e-9));
    });

    test('прямое и обратное преобразование возвращают исходный цвет', () {
      for (final c in const [
        blue,
        orange,
        Color(0xFF747474),
        Color(0xFF00FF00),
        Color(0xFF161618),
      ]) {
        final back = fromOklab(toOklab(c));
        expect(back.r, closeTo(c.r, 1e-5), reason: '$c');
        expect(back.g, closeTo(c.g, 1e-5), reason: '$c');
        expect(back.b, closeTo(c.b, 1e-5), reason: '$c');
      }
    });
  });

  group('lerpOklch', () {
    test('на t = 0 и t = 1 возвращает концы', () {
      expect(lerpOklch(blue, orange, 0), blue);
      expect(lerpOklch(blue, orange, 1), orange);
    });

    test('середина синий↔оранжевый не серее концов', () {
      final mid = lerpOklch(blue, orange, 0.5);
      final srgbMid = Color.lerp(blue, orange, 0.5)!;
      final minEnd = math.min(_chroma(blue), _chroma(orange));

      // В sRGB (и в декартовом OKLab) середина почти серая.
      expect(_chroma(srgbMid), lessThan(0.35 * minEnd));
      expect(_chroma(mid), greaterThan(0.9 * minEnd));
    });

    test('оттенок идёт по короткой дуге', () {
      const pinkRed = Color(0xFFE0245E);
      final ha = _hue(blue);
      final hb = _hue(pinkRed);
      final hm = _hue(lerpOklch(blue, pinkRed, 0.5));

      expect(
        _hueDistance(ha, hm) + _hueDistance(hm, hb),
        closeTo(_hueDistance(ha, hb), 2),
      );
    });

    test('от чёрного к цветному оттенок сразу цветного конца', () {
      for (final t in const [0.01, 0.25, 0.5, 0.75]) {
        final c = lerpOklch(const Color(0xFF000000), orange, t);
        expect(_hueDistance(_hue(c), _hue(orange)), lessThan(1), reason: 't=$t');
      }
    });

    test('от тонированного серого оттенок не пробегает чужие цвета', () {
      const grey = Color(0xFF161618);
      final arc = _hueDistance(_hue(grey), _hue(orange));
      var previous = arc;
      for (final t in const [0.1, 0.25, 0.5, 0.75]) {
        final h = _hue(lerpOklch(grey, orange, t));
        final toOrange = _hueDistance(h, _hue(orange));
        // На короткой дуге между концами и всё ближе к цветному концу.
        expect(
          _hueDistance(_hue(grey), h) + toOrange,
          closeTo(arc, 0.5),
          reason: 't=$t',
        );
        expect(toOrange, lessThan(previous), reason: 't=$t');
        previous = toOrange;
      }
      expect(previous, lessThan(3));
    });

    test('альфа интерполируется линейно', () {
      final mid = lerpOklch(
        const Color(0x00FFFFFF),
        const Color(0xFFFFFFFF),
        0.5,
      );
      expect(mid.a, closeTo(0.5, 1e-9));
    });

    test('у тонированного серого нет рывка в начале перехода', () {
      const warmGrey = Color(0xFF2A2623);
      const tintedGreys = [Color(0xFF23262A), Color(0xFF2A2326)];
      for (final to in [blue, ...tintedGreys]) {
        final start = toOklab(warmGrey);
        final next = toOklab(lerpOklch(warmGrey, to, 0.001));
        final delta = math.sqrt(
          math.pow(next.l - start.l, 2) +
              math.pow(next.a - start.a, 2) +
              math.pow(next.b - start.b, 2),
        );
        expect(delta, lessThan(0.002), reason: '$to');
      }
    });

    test('NaN в t возвращает начальный цвет', () {
      expect(lerpOklch(blue, orange, double.nan), blue);
    });
  });

  group('AppColors.lerp', () {
    final blueTheme =
        AppColors.fromPerceptualPalette(buildPerceptualPalette(0xFF1E5BFF, const []));
    final orangeTheme =
        AppColors.fromPerceptualPalette(buildPerceptualPalette(0xFFFF8A1E, const []));

    test('на концах совпадает с исходными палитрами', () {
      expect(AppColors.lerp(blueTheme, orangeTheme, 0), blueTheme);
      expect(AppColors.lerp(blueTheme, orangeTheme, 1), orangeTheme);
    });

    test('цвета в середине перехода считаются в OKLCh', () {
      final mid = AppColors.lerp(blueTheme, orangeTheme, 0.5);

      expect(mid.accent, lerpOklch(blueTheme.accent, orangeTheme.accent, 0.5));
      expect(
        mid.textSecondary,
        lerpOklch(blueTheme.textSecondary, orangeTheme.textSecondary, 0.5),
      );
      for (var i = 0; i < meshColorCount; i++) {
        expect(
          mid.meshColors[i],
          lerpOklch(blueTheme.meshColors[i], orangeTheme.meshColors[i], 0.5),
        );
      }
    });
  });
}
