// lib/ui/pages/player/player_progress_bar.dart
//
// Прогресс-бар с перемоткой (drag/tap) и тактильной отдачей.
// Вынесен из player_page.dart (декомпозиция монолита, план §1.3).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/haptic_helper.dart';
import '../../../core/player_service_interface.dart';
import '../../../core/providers.dart';

class PlayerProgressBar extends ConsumerStatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.player,
    required this.colors,
    this.fallbackDuration,
  });
  final PlayerServiceInterface player;
  final AppColors colors;
  final Duration? fallbackDuration;

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar>
    with SingleTickerProviderStateMixin {
  double? _dragFraction;

  late final AnimationController _thumbAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 50),
    value: 0,
  );

  double _lastHapticFraction = -1.0;
  static const double _hapticStep = 0.015;
  static const int _hapticCooldownMs = 40;
  DateTime? _lastHapticTime;

  @override
  void dispose() {
    _thumbAnim.dispose();
    super.dispose();
  }

  void _maybeHaptic(double currentFraction) {
    final enabled = ref.read(vibrationEnabledProvider);
    if (!enabled) return;
    final now = DateTime.now();
    if (_lastHapticTime != null) {
      final elapsed = now.difference(_lastHapticTime!).inMilliseconds;
      if (elapsed < _hapticCooldownMs) return;
    }

    if ((currentFraction - _lastHapticFraction).abs() >= _hapticStep) {
      _lastHapticFraction = currentFraction;
      _lastHapticTime = now;
      HapticHelper.microTick(ref: ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pos = (widget.player.positionStream);

    return StreamBuilder<Duration>(
      stream: pos,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: widget.player.durationStream,
          builder: (context, durSnap) {
            final position = posSnap.data ?? Duration.zero;
            final duration =
                durSnap.data ?? widget.fallbackDuration ?? Duration.zero;
            final maxMs = duration.inMilliseconds.toDouble();
            final realF = maxMs > 0
                ? (position.inMilliseconds / maxMs).clamp(0.0, 1.0)
                : 0.0;
            final f = _dragFraction ?? realF;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (_, c) {
                    final width = c.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (d) {
                        _thumbAnim.forward();
                        _lastHapticFraction = -1.0;
                      },
                      onHorizontalDragUpdate: (d) {
                        final newFraction = (d.localPosition.dx / width).clamp(
                          0.0,
                          1.0,
                        );
                        setState(() {
                          _dragFraction = newFraction;
                        });
                        _maybeHaptic(newFraction);
                      },
                      onHorizontalDragEnd: (_) {
                        _thumbAnim.reverse();
                        if (_dragFraction != null && maxMs > 0) {
                          widget.player.seek(
                            Duration(
                              milliseconds: (_dragFraction! * maxMs).round(),
                            ),
                          );
                        }
                        setState(() {
                          _dragFraction = null;
                          _lastHapticFraction = -1.0;
                        });
                      },
                      onTapDown: (d) {
                        _thumbAnim.forward();
                        _lastHapticFraction = -1.0;
                      },
                      onTapUp: (d) {
                        _thumbAnim.reverse();
                        final frac = (d.localPosition.dx / width).clamp(
                          0.0,
                          1.0,
                        );
                        if (maxMs > 0) {
                          widget.player.seek(
                            Duration(milliseconds: (frac * maxMs).round()),
                          );
                        }
                        HapticHelper.light(ref: ref);
                        setState(() {
                          _dragFraction = null;
                          _lastHapticFraction = -1.0;
                        });
                      },
                      onTapCancel: () {
                        _thumbAnim.reverse();
                        setState(() {
                          _dragFraction = null;
                          _lastHapticFraction = -1.0;
                        });
                      },
                      child: Container(
                        color: Colors.transparent,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 30),
                              child: CustomPaint(
                                size: const Size(double.infinity, 14),
                                painter: _ProgressPainter(
                                  fraction: f,
                                  thumbAnim: _thumbAnim,
                                  colors: widget.colors,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _fmt(
                                      maxMs > 0
                                          ? Duration(
                                              milliseconds: (f * maxMs).round(),
                                            )
                                          : position,
                                    ),
                                    style: TextStyle(
                                      color: widget.colors.textPrimary,
                                      fontSize: 12,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    _fmt(duration),
                                    style: TextStyle(
                                      color: widget.colors.textSecondary,
                                      fontSize: 12,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.fraction,
    required this.thumbAnim,
    required this.colors,
  }) : super(repaint: thumbAnim);

  final double fraction;
  final Animation<double> thumbAnim;
  final AppColors colors;

  static const _trackHeight = 10.0;
  static const _thumbWidthNormal = 8.0;
  static const _thumbHeightNormal = 48.0;
  static const _thumbHeightDragging = 48.0;
  static const _thumbRadius = 4.0;
  static const _gapDragging = 6.0;
  static const _gapNormal = 4.0;
  static const _thumbWidthDragging = 4.0;
  static const _margin = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final totalWidth = size.width - _margin * 2;
    final filledW = totalWidth * fraction.clamp(0.0, 1.0);

    final double t = thumbAnim.value;

    final double thumbWidth =
        _thumbWidthNormal + (_thumbWidthDragging - _thumbWidthNormal) * t;
    final double thumbHeight =
        _thumbHeightNormal + (_thumbHeightDragging - _thumbHeightNormal) * t;
    final double gap = _gapNormal + (_gapDragging - _gapNormal) * t;

    final double thumbCornerRadius = 2 + 2 * t;

    final double thumbX = _margin + filledW - thumbWidth / 2;
    final double clampedThumbX = thumbX.clamp(
      _margin,
      _margin + totalWidth - thumbWidth,
    );

    if (clampedThumbX + thumbWidth + gap < _margin + totalWidth) {
      final double trackStart = clampedThumbX + thumbWidth + gap;
      final double trackWidth = (_margin + totalWidth) - trackStart;

      final trackRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
          trackStart,
          centerY - _trackHeight / 2,
          trackWidth,
          _trackHeight,
        ),
        topLeft: Radius.circular(thumbCornerRadius),
        topRight: const Radius.circular(_trackHeight / 2),
        bottomLeft: Radius.circular(thumbCornerRadius),
        bottomRight: const Radius.circular(_trackHeight / 2),
      );
      final trackPaint = Paint()
        ..color = colors.elevated.withValues(alpha: 0.5);
      canvas.drawRRect(trackRect, trackPaint);
    }

    if (clampedThumbX > _margin + gap) {
      final double filledWidth = clampedThumbX - gap - _margin;

      final filledRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
          _margin,
          centerY - _trackHeight / 2,
          filledWidth,
          _trackHeight,
        ),
        topLeft: const Radius.circular(_trackHeight / 2),
        topRight: Radius.circular(thumbCornerRadius),
        bottomLeft: const Radius.circular(_trackHeight / 2),
        bottomRight: Radius.circular(thumbCornerRadius),
      );
      final filledPaint = Paint()..color = colors.elevatedHi;
      canvas.drawRRect(filledRect, filledPaint);
    }

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        clampedThumbX,
        centerY - thumbHeight / 2,
        thumbWidth,
        thumbHeight,
      ),
      const Radius.circular(_thumbRadius),
    );
    final thumbPaint = Paint()..color = colors.elevatedHi;
    canvas.drawRRect(thumbRect, thumbPaint);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) {
    return old.fraction != fraction ||
        old.thumbAnim.value != thumbAnim.value ||
        old.colors != colors;
  }
}