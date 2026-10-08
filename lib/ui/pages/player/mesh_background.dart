import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// Полный цикл движения пятен: частоты в [meshBlobCenters] кратны ему.
const _cycle = Duration(seconds: 120);

/// Шаг фазы за кадр не больше этого: после паузы (свёрнутый плеер, тикер
/// заглушён, а его elapsed идёт) пятна не прыгают.
const _maxStep = Duration(milliseconds: 100);

/// Сдвигает фазу движения пятен на [dt], результат в [0, 2π).
@visibleForTesting
double advanceMeshPhase(double phase, Duration dt) {
  final step = dt > _maxStep ? _maxStep : dt;
  final next = phase + step.inMicroseconds / _cycle.inMicroseconds * 2 * math.pi;
  return next % (2 * math.pi);
}

/// Центры четырёх пятен в долях экрана для фазы [t]. Считаются на CPU в
/// double: в шейдере тригонометрия по фазе стоила бы 8 вызовов на пиксель.
@visibleForTesting
List<Offset> meshBlobCenters(double t) => [
      Offset(0.30 + 0.20 * math.sin(3 * t), 0.22 + 0.12 * math.cos(2 * t)),
      Offset(0.72 + 0.18 * math.cos(4 * t), 0.35 + 0.15 * math.sin(3 * t)),
      Offset(0.40 + 0.22 * math.cos(2 * t), 0.70 + 0.14 * math.sin(5 * t)),
      Offset(0.65 + 0.20 * math.sin(5 * t), 0.88 + 0.10 * math.cos(4 * t)),
    ];

/// Анимированный mesh-фон из цветов обложки (shaders/mesh_gradient.frag).
///
/// Пока шейдер грузится или если он не загрузился, не рисует ничего: под ним
/// лежит градиент [PlayerBackground]. Тикер подчиняется [TickerMode], поэтому
/// в свёрнутом плеере анимация стоит.
class MeshBackground extends StatefulWidget {
  const MeshBackground({super.key, required this.colors});

  /// Четыре цвета пятен; плавную смену даёт анимированная палитра.
  final List<Color> colors;

  static const _asset = 'shaders/mesh_gradient.frag';

  /// Загрузчик программы; подменяется в тестах.
  @visibleForTesting
  static Future<ui.FragmentProgram> Function() loadProgram = _loadAsset;

  static Future<ui.FragmentProgram> _loadAsset() =>
      ui.FragmentProgram.fromAsset(_asset);

  /// Программа компилируется один раз на всё приложение. Неудача тоже
  /// кэшируется: повторять загрузку на каждом треке бессмысленно.
  static Future<ui.FragmentProgram>? _program;

  @visibleForTesting
  static void resetForTesting() {
    _program = null;
    loadProgram = _loadAsset;
  }

  @override
  State<MeshBackground> createState() => _MeshBackgroundState();
}

class _MeshBackgroundState extends State<MeshBackground>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  final _phase = ValueNotifier<double>(0);
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final program =
          await (MeshBackground._program ??= MeshBackground.loadProgram());
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      _ticker = createTicker(_onTick)..start();
    } catch (e) {
      // ignore: avoid_print
      print('[MeshBackground] shader load failed: $e');
    }
  }

  void _onTick(Duration elapsed) {
    _phase.value = advanceMeshPhase(_phase.value, elapsed - _lastElapsed);
    _lastElapsed = elapsed;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _phase.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) return const SizedBox.expand();

    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _MeshPainter(shader, widget.colors, _phase),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter(this.shader, this.colors, this.phase) : super(repaint: phase);

  final ui.FragmentShader shader;
  final List<Color> colors;
  final ValueListenable<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    // Порядок uniform — как в mesh_gradient.frag.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height);
    final centers = meshBlobCenters(phase.value);
    for (var i = 0; i < 4; i++) {
      shader
        ..setFloat(2 + i * 2, centers[i].dx)
        ..setFloat(3 + i * 2, centers[i].dy);
    }
    for (var i = 0; i < 4; i++) {
      final c = colors[i % colors.length];
      final base = 10 + i * 4;
      shader
        ..setFloat(base, c.r)
        ..setFloat(base + 1, c.g)
        ..setFloat(base + 2, c.b)
        ..setFloat(base + 3, c.a);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.shader != shader || !listEquals(old.colors, colors);
}
