// lib/ui/pages/player/player_bottom_actions.dart
//
// Нижняя панель действий плеера: loop, очередь (свайп вверх), доп. меню.
// Вынесена из player_page.dart (декомпозиция монолита, план §1.3).

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/providers/global_theme_provider.dart';
import '../../../core/platform/haptic_helper.dart';
import '../../../core/player_service_interface.dart';
import '../../../models/track.dart';
import '../../widgets/queue_sheet.dart';
import '../../widgets/track_settings_sheet.dart';

class PlayerBottomActions extends ConsumerStatefulWidget {
  const PlayerBottomActions({
    super.key,
    required this.player,
    required this.item,
    required this.queueCtrl,
    required this.colors,
  });
  final PlayerServiceInterface player;
  final MediaItem item;
  final QueueSheetController queueCtrl;
  final AppColors colors;

  @override
  ConsumerState<PlayerBottomActions> createState() =>
      _PlayerBottomActionsState();
}

class _PlayerBottomActionsState extends ConsumerState<PlayerBottomActions> {
  bool _queueDragged = false;
  double _startFingerY = 0;
  double _startValue = 0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 5),
        StreamBuilder<LoopMode>(
          stream: widget.player.loopModeStream,
          initialData: widget.player.loopMode,
          builder: (context, snap) {
            final loop = snap.data ?? LoopMode.off;
            return _PlayerSquircleButton(
              icon: loop == LoopMode.one
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded,
              highlighted: loop != LoopMode.off,
              onTap: widget.player.cycleLoopMode,
              shape: BoxShape.circle,
              colors: widget.colors,
            );
          },
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (d) {
              _queueDragged = false;
              _startFingerY = d.globalPosition.dy;
              _startValue = widget.queueCtrl.value;
            },
            onVerticalDragUpdate: (d) {
              final currentFingerY = d.globalPosition.dy;
              final rawDy = _startFingerY - currentFingerY;

              final dy = rawDy > 10
                  ? rawDy - 10
                  : (rawDy < -10 ? rawDy + 10 : 0);

              if (!_queueDragged && rawDy > 5) {
                _queueDragged = true;
              }

              if (_queueDragged && dy != 0) {
                const dragDistanceForFullOpen = 690.0;
                final valueShift = dy / dragDistanceForFullOpen;
                final newValue = (_startValue + valueShift).clamp(0.0, 1.0);
                widget.queueCtrl.setValue(newValue);
              }
            },
            onVerticalDragEnd: (d) {
              if (_queueDragged) {
                widget.queueCtrl.settle(
                  d.primaryVelocity ?? 0,
                  fromButton: true,
                );
                _queueDragged = false;
              }
            },
            child: Material(
              color: widget.colors.elevated,
              borderRadius: BorderRadius.circular(28),
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () {
                  HapticHelper.tripleTick(ref: ref);
                  widget.queueCtrl.openPart();
                },
                child: SizedBox(
                  height: 56,
                  child: Center(
                    child: Icon(
                      Icons.queue_music_rounded,
                      color: widget.colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _PlayerSquircleButton(
          icon: Icons.more_horiz_rounded,
          onTap: () => _showExtra(context),
          shape: BoxShape.circle,
          colors: widget.colors,
        ),
        const SizedBox(width: 5),
      ],
    );
  }

  void _showExtra(BuildContext context) {
    final m = widget.item;
    final track = Track(
      id: m.extras?['trackId'] as String? ?? m.id,
      sourceId: m.extras?['sourceId'] as String? ?? '',
      title: m.title,
      artist: m.artist ?? '',
      duration: m.duration,
      artworkUrl: m.artUri?.toString(),
    );

    showTrackSettingsSheet(context, track: track, currentMediaItem: m);
  }
}

class _PlayerSquircleButton extends StatelessWidget {
  const _PlayerSquircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
    this.highlighted = false,
    this.shape = BoxShape.rectangle,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;
  final BoxShape shape;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final isCircle = shape == BoxShape.circle;

    return Material(
      color: colors.elevated,
      shape: isCircle ? const CircleBorder() : null,
      borderRadius: isCircle ? null : BorderRadius.circular(32),
      child: InkWell(
        customBorder: isCircle ? const CircleBorder() : null,
        borderRadius: isCircle ? null : BorderRadius.circular(32),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(
            icon,
            color: highlighted ? colors.accent : colors.textPrimary,
          ),
        ),
      ),
    );
  }
}