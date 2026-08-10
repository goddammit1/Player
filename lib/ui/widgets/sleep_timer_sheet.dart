// lib/ui/sheets/sleep_timer_sheet.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptic_helper.dart';
import '../../core/providers.dart';
import 'desktop_layout.dart';

Future<void> showSleepTimerSheet(BuildContext context) {
  if (ModalRoute.of(context)?.isCurrent != true) return Future.value();
  return showDesktopModalSheet<void>(
    context: context,
    maxWidth: 520,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    useRootNavigator: true,
    builder: (sheetCtx) => const _SleepTimerSheet(),
  );
}

// =============================================================================
// КАСТОМНАЯ ФИЗИКА СКРОЛЛА
// =============================================================================

class _ViscousScrollPhysics extends ScrollPhysics {
  const _ViscousScrollPhysics({super.parent});

  @override
  _ViscousScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ViscousScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    return super.applyPhysicsToUserOffset(position, offset * 0.75);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final double clampedVelocity = velocity.clamp(-650.0, 650.0);
    return super.createBallisticSimulation(position, clampedVelocity);
  }
}

// =============================================================================
// WIDGET
// =============================================================================

class _SleepTimerSheet extends ConsumerStatefulWidget {
  const _SleepTimerSheet();

  @override
  ConsumerState<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends ConsumerState<_SleepTimerSheet> {
  late ScrollController _scrollController;

  /// Выбранный индекс риски (0 = Off, 1 = 5 min, 2 = 6 min...)
  int _selectedIndex = 0;

  /// Преобразование индекса риски в минуты:
  /// Index 0 -> 0 min (Off)
  /// Index 1 -> 5 min
  /// Index 2 -> 6 min ... Index 116 -> 120 min
  int _indexToMinutes(int index) {
    if (index <= 0) return 0;
    return index + 4;
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(initialScrollOffset: 0.0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool _onScrollNotification(
    ScrollNotification scrollInfo,
    double tickSpacing,
  ) {
    if (scrollInfo is ScrollUpdateNotification) {
      int newIndex = (_scrollController.offset / tickSpacing).round();
      newIndex = newIndex.clamp(0, 116); // 116 + 4 = 120 минут макс.
      if (newIndex != _selectedIndex) {
        HapticHelper.microTick(ref: ref);
        setState(() => _selectedIndex = newIndex);
      }
    } else if (scrollInfo is ScrollEndNotification) {
      int targetIndex = (_scrollController.offset / tickSpacing).round();
      targetIndex = targetIndex.clamp(0, 116);

      Future.microtask(() {
        if (mounted && _scrollController.hasClients) {
          _scrollController.animateTo(
            targetIndex * tickSpacing,
            duration: const Duration(milliseconds: 500),
            curve: Curves.elasticOut,
          );
        }
      });
    }
    return false;
  }

  void _onSetTapped() {
    HapticHelper.medium(ref: ref);
    final player = ref.read(playerServiceProvider);
    final minutes = _indexToMinutes(_selectedIndex);

    if (minutes == 0) {
      player.cancelSleepTimer();
    } else {
      player.startSleepTimer(Duration(minutes: minutes));
    }
    Navigator.of(context).pop();
  }

  void _onEndOfSongTapped() {
    HapticHelper.light(ref: ref);
    final player = ref.read(playerServiceProvider);
    player.setStopAtEndOfSong();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final minutes = _indexToMinutes(_selectedIndex);

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Drag handle ──
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ── Title ──
            Text(
              'Sleep Timer',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 32),

            // ── Time Display ──
            Text(
              minutes == 0 ? 'Off' : '$minutes min',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 48,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),

            const SizedBox(height: 32),

            // ── Dynamic Tick Picker ──
            SizedBox(
              height: 48,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double tickSpacing = constraints.maxWidth / 17.0;
                  final double halfWidth = constraints.maxWidth / 2;

                  return NotificationListener<ScrollNotification>(
                    onNotification: (info) =>
                        _onScrollNotification(info, tickSpacing),
                    child: ListView.builder(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      physics: const _ViscousScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: halfWidth - (tickSpacing / 2),
                      ),
                      itemCount: 117, // Индексы 0..116 (Off, 5, 6, 7 ... 120)
                      itemBuilder: (context, index) {
                        return AnimatedBuilder(
                          animation: _scrollController,
                          builder: (context, _) {
                            final double scrollOffset =
                                _scrollController.hasClients
                                ? _scrollController.offset
                                : 0.0;

                            final double itemOffset = index * tickSpacing;
                            final double distFromCenter =
                                (itemOffset - scrollOffset).abs();

                            final double stepDist =
                                distFromCenter / tickSpacing;

                            final double centerFactor = (1.0 - stepDist).clamp(
                              0.0,
                              1.0,
                            );

                            // 1. Прозрачность (Opacity)
                            double opacity;
                            if (stepDist > 8.5) {
                              opacity = 0.0;
                            } else if (stepDist <= 2.0) {
                              opacity = 1.0 - (stepDist / 2.0) * 0.30;
                            } else {
                              final double progress = ((stepDist - 2.0) / 6.0)
                                  .clamp(0.0, 1.0);
                              opacity = 0.70 - (progress * 0.55);
                            }

                            // 2. Ширина
                            final double tickWidth = 3.0 + (3.0 * centerFactor);

                            // 3. Высота
                            double tickHeight;
                            if (stepDist <= 1.0) {
                              tickHeight = 12.0 + (12.0 * centerFactor);
                            } else {
                              final double edgeProgress =
                                  ((stepDist - 1.0) / 7.0).clamp(0.0, 1.0);
                              tickHeight = 12.0 - (6.0 * edgeProgress);
                            }

                            // 4. Смещение вверх на 2px
                            final double shiftY = -8.0 * centerFactor;

                            return Container(
                              width: tickSpacing,
                              height: 48,
                              alignment: Alignment.center,
                              child: Transform.translate(
                                offset: Offset(0, shiftY),
                                child: Container(
                                  width: tickWidth,
                                  height: tickHeight,
                                  decoration: BoxDecoration(
                                    color: Color.lerp(
                                      colors.textPrimary.withValues(
                                        alpha: opacity,
                                      ),
                                      colors.textPrimary,
                                      centerFactor,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // ── End of song ──
            TextButton(
              onPressed: _onEndOfSongTapped,
              style: TextButton.styleFrom(
                splashFactory: NoSplash.splashFactory,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'End of song',
                    style: TextStyle(color: colors.textSecondary, fontSize: 16),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.textSecondary,
                    size: 20,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 48),

            // ── Set Button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Material(
                color: colors.elevatedHi,
                borderRadius: BorderRadius.circular(32),
                child: InkWell(
                  onTap: _onSetTapped,
                  borderRadius: BorderRadius.circular(32),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    alignment: Alignment.center,
                    child: Text(
                      'Set',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
