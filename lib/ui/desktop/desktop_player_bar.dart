// lib/ui/desktop/desktop_player_bar.dart

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import 'design/dimens.dart';

class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  /// Высота панели плеера
  static const double height = 96.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final colors = ref.watch(animatedPaletteProvider);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(Dimens.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snap) {
          final item = snap.data;
          if (item == null) {
            return Center(
              child: Text(
                'No track playing',
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            );
          }

          // Отступы ровно 12px от всех краёв панели
          return Padding(
            padding: const EdgeInsets.all(12.0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Вычисляем допустимую ширину под левый блок, чтобы не наезжать на центр
                final maxSideWidth =
                    ((constraints.maxWidth - 580) / 2).clamp(160.0, 340.0);

                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // 1. Левый блок трека (прижат к левому краю, отступ 12px задан родителем)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxSideWidth),
                        child: _TrackInfo(item: item, colors: colors),
                      ),
                    ),

                    // 2. Блок управления и таймлайн — СТРОГО ПО ЦЕНТРУ ВСЕЙ ШИРИНЫ
                    Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: _ControlsAndTimeline(
                          player: player,
                          colors: colors,
                        ),
                      ),
                    ),

                    // 3. Блок громкости (прижат к правому краю)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16.0), // <-- Отступ от правого края
                        child: _VolumeSlider(player: player, colors: colors),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Увеличенная обложка 72x72 и информация о треке
class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.item, required this.colors});

  final MediaItem item;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final sourceId = (item.extras?['sourceId'] as String?)?.toUpperCase();
    final quality = (item.extras?['qualityLabel'] as String?)?.toUpperCase();
    final meta = [
      if (sourceId != null && sourceId.isNotEmpty) sourceId else 'Muzmo',
      if (quality != null && quality.isNotEmpty) quality else '320 kbps'
    ].join(' • ');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Обложка ровно 72x72 (высота 96px минус отступы по 12px сверху и снизу)
        Artwork(
          url: item.artUri?.toString(),
          size: 72,
          borderRadius: 22,
          trackId: (item.extras?['trackId'] as String?) ?? item.id,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ControlsAndTimeline extends StatelessWidget {
  const _ControlsAndTimeline({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final navCtx = rootNavigatorKey.currentContext;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Add to playlist
            _BarIconButton(
              icon: Icons.playlist_add_rounded,
              size: 20,
              colors: colors,
              onPressed: () {
                final list = player.trackQueue;
                final idx = player.currentIndex;
                if (navCtx != null && idx >= 0 && idx < list.length) {
                  showAddToPlaylistSheet(navCtx, list[idx]);
                }
              },
            ),
            // Shuffle
            _BarIconButton(
              icon: Icons.shuffle_rounded,
              size: 18,
              colors: colors,
              onPressed: player.shuffleQueue,
            ),
            // Previous
            _BarIconButton(
              icon: Icons.skip_previous_rounded,
              size: 24,
              color: colors.textPrimary,
              colors: colors,
              onPressed: player.skipToPrevious,
            ),
            // Play / Pause с лоадером
            _PlayPauseButton(player: player, colors: colors),
            // Next
            _BarIconButton(
              icon: Icons.skip_next_rounded,
              size: 24,
              color: colors.textPrimary,
              colors: colors,
              onPressed: player.skipToNext,
            ),
            // Repeat
            _LoopButton(player: player, colors: colors),
            // Queue / Lyrics
            _BarIconButton(
              icon: Icons.queue_music_rounded,
              size: 19,
              colors: colors,
              onPressed: () {},
            ),
          ],
        ),
        const SizedBox(height: 2),
        _TimelineSlider(player: player, colors: colors),
      ],
    );
  }
}

/// Кнопка панели с плавной hover-подложкой
class _BarIconButton extends StatefulWidget {
  const _BarIconButton({
    required this.icon,
    required this.colors,
    required this.onPressed,
    this.size = 20,
    this.color,
  });

  final IconData icon;
  final double size;
  final Color? color;
  final AppColors colors;
  final VoidCallback onPressed;

  @override
  State<_BarIconButton> createState() => _BarIconButtonState();
}

class _BarIconButtonState extends State<_BarIconButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final targetColor = widget.color ??
        (_isHovered ? widget.colors.textPrimary : widget.colors.textSecondary);
    final hoverCircleColor = widget.colors.elevatedHi.withValues(alpha: 0.35);
    final scale = (_isHovered && !_isPressed) ? 1.10 : 1.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                opacity: _isHovered ? 1.0 : 0.0,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hoverCircleColor,
                  ),
                ),
              ),
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                child: TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOut,
                  tween: ColorTween(end: targetColor),
                  builder: (context, color, child) {
                    return Icon(widget.icon, color: color, size: widget.size);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineSlider extends StatefulWidget {
  const _TimelineSlider({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  State<_TimelineSlider> createState() => _TimelineSliderState();
}

class _TimelineSliderState extends State<_TimelineSlider> {
  Duration? _dragValue;
  late final Stream<Duration> _positionThrottled;
  StreamSubscription<MediaItem?>? _itemSub;

  @override
  void initState() {
    super.initState();
    _positionThrottled = widget.player.positionStream
        .throttleTime(const Duration(milliseconds: 100));
    _itemSub = widget.player.mediaItem.listen((_) {
      if (_dragValue != null && mounted) setState(() => _dragValue = null);
    });
  }

  @override
  void dispose() {
    _itemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: _positionThrottled,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: widget.player.durationStream,
          builder: (context, durSnap) {
            final pos = _dragValue ?? posSnap.data ?? Duration.zero;
            final dur = durSnap.data ??
                widget.player.mediaItemValue?.duration ??
                Duration.zero;
            final known = dur > Duration.zero;
            final maxMs = known
                ? dur.inMilliseconds.toDouble().clamp(1.0, double.infinity)
                : 1.0;
            final value =
                known ? (pos.inMilliseconds / maxMs).clamp(0.0, 1.0) : 0.0;

            return Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    _fmt(known ? pos : null),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: widget.colors.textSecondary,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PlayerSlider(
                    key: const Key('seek_slider'),
                    value: value,
                    colors: widget.colors,
                    onChanged: known
                        ? (v) => setState(() => _dragValue =
                            Duration(milliseconds: (v * maxMs).round()))
                        : null,
                    onChangeEnd: known
                        ? (v) {
                            final target =
                                Duration(milliseconds: (v * maxMs).round());
                            widget.player.seek(target);
                            Future.delayed(const Duration(milliseconds: 180),
                                () {
                              if (mounted && _dragValue == target) {
                                setState(() => _dragValue = null);
                              }
                            });
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 40,
                  child: Text(
                    _fmt(known ? dur : null),
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: widget.colors.textSecondary,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snap) {
        final st = snap.data;
        final loading = st != null &&
            (st.processingState == AudioProcessingState.loading ||
                st.processingState == AudioProcessingState.buffering);

        if (loading) {
          return Padding(
            padding: const EdgeInsets.all(9),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: colors.textPrimary,
              ),
            ),
          );
        }

        return StreamBuilder<bool>(
          stream: player.playingStream,
          builder: (context, playingSnap) {
            final playing = playingSnap.data ?? st?.playing ?? false;
            return _BarIconButton(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 28,
              color: colors.textPrimary,
              colors: colors,
              onPressed: () => playing ? player.pause() : player.play(),
            );
          },
        );
      },
    );
  }
}

class _LoopButton extends StatelessWidget {
  const _LoopButton({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LoopMode>(
      stream: player.loopModeStream,
      builder: (context, snap) {
        final mode = snap.data ?? LoopMode.off;
        final active = mode != LoopMode.off;
        return _BarIconButton(
          icon: mode == LoopMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          size: 20,
          color: active ? colors.elevatedHi : null,
          colors: colors,
          onPressed: player.cycleLoopMode,
        );
      },
    );
  }
}

class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  double _lastNonZeroVolume = 1.0;

  void _toggleMute(double current) {
    if (current > 0.0) {
      _lastNonZeroVolume = current;
      widget.player.setVolume(0.0);
    } else {
      widget.player.setVolume(_lastNonZeroVolume > 0 ? _lastNonZeroVolume : 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: widget.player.volumeStream,
      builder: (context, snap) {
        final v = (snap.data ?? 1.0).clamp(0.0, 1.0);
        final IconData icon = v == 0.0
            ? Icons.volume_off_rounded
            : v < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BarIconButton(
              icon: icon,
              size: 20,
              colors: widget.colors,
              onPressed: () => _toggleMute(v),
            ),
            const SizedBox(width: 8), // <-- Увеличен зазор с 4 до 8
            _PlayerSlider(
              width: 96,
              value: v,
              colors: widget.colors,
              onChanged: (val) {
                if (val > 0) _lastNonZeroVolume = val;
                widget.player.setVolume(val);
              },
            ),
          ],
        );
      },
    );
  }
}

class _PlayerSlider extends StatefulWidget {
  const _PlayerSlider({
    super.key,
    this.width,
    required this.value,
    required this.colors,
    this.onChanged,
    this.onChangeEnd,
  });

  final double? width;
  final double value;
  final AppColors colors;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_PlayerSlider> createState() => _PlayerSliderState();
}

class _PlayerSliderState extends State<_PlayerSlider> {
  bool _hovered = false;
  bool _dragging = false;
  double _localValue = 0.0;

  double get _value => _dragging ? _localValue : widget.value;

  void _handlePosition(double dx, double totalWidth) {
    if (totalWidth <= 0) return;
    final v = (dx / totalWidth).clamp(0.0, 1.0);
    setState(() {
      _dragging = true;
      _localValue = v;
    });
    widget.onChanged?.call(v);
  }

  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(_localValue);
  }

  @override
  Widget build(BuildContext context) {
    final showThumb = _hovered || _dragging;
    final trackHeight = (_hovered || _dragging) ? 6.0 : 3.0;

    Widget buildSliderTrack(double effectiveWidth) {
      final fillWidth = (effectiveWidth * _value).clamp(0.0, effectiveWidth);
      const thumbRadius = 6.5;

      return MouseRegion(
        cursor: widget.onChanged != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onChanged != null
              ? (d) => _handlePosition(d.localPosition.dx, effectiveWidth)
              : null,
          onTapUp: widget.onChanged != null ? (_) => _endDrag() : null,
          onHorizontalDragStart: widget.onChanged != null
              ? (d) => _handlePosition(d.localPosition.dx, effectiveWidth)
              : null,
          onHorizontalDragUpdate: widget.onChanged != null
              ? (d) => _handlePosition(d.localPosition.dx, effectiveWidth)
              : null,
          onHorizontalDragEnd:
              widget.onChanged != null ? (_) => _endDrag() : null,
          onHorizontalDragCancel:
              widget.onChanged != null ? () => _endDrag() : null,
          child: SizedBox(
            width: effectiveWidth,
            height: 28, // Компактная область захвата под 96px общую высоту
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: effectiveWidth,
                  height: trackHeight,
                  decoration: BoxDecoration(
                    color: widget.colors.textSecondary.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: fillWidth,
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: widget.colors.textPrimary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: (fillWidth - thumbRadius).clamp(
                    -thumbRadius / 2,
                    effectiveWidth - thumbRadius * 1.5,
                  ),
                  child: AnimatedScale(
                    scale: showThumb ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutBack,
                    child: Container(
                      width: thumbRadius * 2,
                      height: thumbRadius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.colors.textPrimary,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (widget.width != null) {
      return buildSliderTrack(widget.width!);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return buildSliderTrack(constraints.maxWidth);
      },
    );
  }
}