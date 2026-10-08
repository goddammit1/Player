import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Анимированный эквалайзер поверх обложки играющего трека
/// (плейлист, история, кэш).
class WaveBars extends StatefulWidget {
  const WaveBars({super.key, required this.color});
  final Color color;

  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _barCount = 5;
  static const _barWidth = 3.0;
  static const _barGap = 2.0;
  static const _maxHeight = 20.0;
  static const _minHeight = 4.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_barCount, (i) {
            final phase = (i / _barCount) * 2 * math.pi;
            final wave =
                math.sin(t * 2 * math.pi + phase) * 0.5 +
                math.sin(t * 4 * math.pi + phase * 1.5) * 0.3;
            final height =
                _minHeight +
                (_maxHeight - _minHeight) *
                    ((wave + 0.8) / 1.6).clamp(0.0, 1.0);

            return Container(
              width: _barWidth,
              height: height,
              margin: EdgeInsets.only(right: i < _barCount - 1 ? _barGap : 0),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(_barWidth / 2),
              ),
            );
          }),
        );
      },
    );
  }
}
