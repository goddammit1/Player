import 'dart:math' as math;
import 'dart:ui';

// ═══════════════════════════════════════════════════════════════════════════
//  OKLab (Björn Ottosson, 2020): перцептивно равномерное пространство.
//  Смешиваем в полярной форме OKLCh: светлота и насыщенность линейно,
//  оттенок по короткой дуге. Прямая в декартовом OKLab, как и в sRGB, у
//  почти комплементарных цветов (синий↔оранжевый) проходит через серое.
//  Коэффициенты из https://bottosson.github.io/posts/oklab/
// ═══════════════════════════════════════════════════════════════════════════

typedef Oklab = ({double l, double a, double b});

Oklab toOklab(Color c) {
  final r = _toLinear(c.r);
  final g = _toLinear(c.g);
  final b = _toLinear(c.b);

  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

  return (
    l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

/// Обратное преобразование; цвета вне гаммы sRGB обрезаются по каналам.
Color fromOklab(Oklab lab, {double alpha = 1}) {
  final l = _cube(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b);
  final m = _cube(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b);
  final s = _cube(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b);

  return Color.from(
    alpha: alpha,
    red: _fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    green: _fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    blue: _fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
  );
}

/// Аналог [Color.lerp], но цвет смешивается в OKLCh. Альфа — линейно.
///
/// Оттенок поворачивается по короткой дуге, доля поворота взвешена
/// насыщенностью концов: у серого конца оттенка почти нет, и смесь сразу
/// берёт оттенок цветного, не пробегая по чужим. При равной насыщенности
/// это обычная интерполяция OKLCh, на концах скачков нет.
Color lerpOklch(Color a, Color b, double t) {
  if (!(t > 0) || a == b) return a;
  if (t >= 1) return b;

  final x = toOklab(a);
  final y = toOklab(b);
  final cx = math.sqrt(x.a * x.a + x.b * x.b);
  final cy = math.sqrt(y.a * y.a + y.b * y.b);
  final hx = math.atan2(x.b, x.a);
  var dh = math.atan2(y.b, y.a) - hx;
  if (dh > math.pi) dh -= 2 * math.pi;
  if (dh < -math.pi) dh += 2 * math.pi;

  final weight = (1 - t) * cx + t * cy;
  final share = weight > 0 ? t * cy / weight : t;
  final c = _lerp(cx, cy, t);
  final h = hx + dh * share;

  return fromOklab(
    (l: _lerp(x.l, y.l, t), a: c * math.cos(h), b: c * math.sin(h)),
    alpha: _lerp(a.a, b.a, t),
  );
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _cube(double x) => x * x * x;

double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

/// Гамма sRGB → линейная яркость.
double _toLinear(double c) => c <= 0.04045
    ? c / 12.92
    : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// Линейная яркость → гамма sRGB, с обрезкой в [0, 1].
double _fromLinear(double c) {
  final v = c <= 0.0031308
      ? 12.92 * c
      : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;
  return v.clamp(0.0, 1.0);
}
