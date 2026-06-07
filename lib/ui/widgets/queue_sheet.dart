import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../../models/track.dart';
import 'add_to_playlist_sheet.dart';
import '../../core/player_service.dart';
import '../../main.dart' show AppColors;
import 'artwork.dart';
import '../../core/artwork_helper.dart';

extension MediaItemToTrack on MediaItem {
  Track toTrack() {
    final extra = extras ?? {};
    return Track(
      id: id,
      sourceId: extra['source_id'] as String? ?? 'local',
      title: title,
      artist: artist ?? '',
      duration: duration,
      artworkUrl: artUri?.toString(),
      qualityScore: extra['quality_score'] as int?,
      qualityLabel: extra['quality_label'] as String?,
      extra: extra,
    );
  }
}

String _formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final totalSeconds = d.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

class QueueSheetController extends ChangeNotifier {
  QueueSheetController({required this.vsync}) {
    _anim = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 500),
      value: 0,
    )..addListener(notifyListeners);
  }

  final TickerProvider vsync;
  late final AnimationController _anim;

  static const double partPosition = 0.62;
  static const double fullThreshold = 0.82;

  double get value => _anim.value;
  bool get isClosed => _anim.value <= 0.001;
  bool get isFull => _anim.value >= 0.999;

  void openPart() => _anim.animateTo(
        partPosition,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );

  void openFull() => _anim.animateTo(
        1,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );

  void close() => _anim.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );

  void drag(double delta, double maxHeight) {
    if (maxHeight <= 0) return;
    _anim.value = (_anim.value - delta / maxHeight).clamp(0.0, 1.0);
  }

  void setValue(double v) {
    _anim.value = v.clamp(0.0, 1.0);
  }

  void settle(double velocity, {required bool fromButton}) {
    const fling = 700;
    final v = value;

    if (fromButton) {
      if (v >= fullThreshold) {
        openFull();
      } else if (velocity > fling && v < partPosition * 0.6) {
        close();
      } else {
        openPart();
      }
      return;
    }

    if (velocity < -fling) {
      v < partPosition ? openPart() : openFull();
      return;
    }
    if (velocity > fling) {
      v > partPosition ? openPart() : close();
      return;
    }
    final toClose = v;
    final toPart = (v - partPosition).abs();
    final toFull = (1 - v);
    if (toClose < toPart && toClose < toFull) {
      close();
    } else if (toFull < toPart) {
      openFull();
    } else {
      openPart();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }
}

class QueueSheet extends StatelessWidget {
  const QueueSheet({
    super.key,
    required this.controller,
    required this.player,
  });

  final QueueSheetController controller;
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height;
    final topInset = media.padding.top;
    final bottomInset = media.padding.bottom;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        final isClosed = t <= 0.001;

        final contentOpacity = isClosed
            ? 0.0
            : (t / (QueueSheetController.partPosition / 2)).clamp(0.0, 1.0);
        
        final scrimOpacity = (t / QueueSheetController.partPosition * 0.5)
            .clamp(0.0, 0.5);

        const peekOffset = 0.16;
        final closedOffset = maxHeight * (1 - peekOffset);
        final slideOffset = (1 - t) * closedOffset;

        return Positioned.fill(
          child: IgnorePointer(
            ignoring: isClosed,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: controller.close,
                    onVerticalDragUpdate: (d) =>
                        controller.drag(d.primaryDelta ?? 0, maxHeight),
                    onVerticalDragEnd: (d) => controller.settle(
                      d.primaryVelocity ?? 0,
                      fromButton: false,
                    ),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: scrimOpacity),
                    ),
                  ),
                ),

                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(0, slideOffset),
                    child: Opacity(
                      opacity: contentOpacity,
                      child: _QueueBody(
                        controller: controller,
                        player: player,
                        maxHeight: maxHeight,
                        topInset: topInset,
                        bottomInset: bottomInset,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _QueueBody extends StatelessWidget {
  const _QueueBody({
    required this.controller,
    required this.player,
    required this.maxHeight,
    required this.topInset,
    required this.bottomInset,
  });

  final QueueSheetController controller;
  final PlayerService player;
  final double maxHeight;
  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final t = controller.value;
    final fullProgress =
        ((t - QueueSheetController.partPosition) /
                (1 - QueueSheetController.partPosition))
            .clamp(0.0, 1.0);
    final topPad = topInset * fullProgress;

    final visibleHeight = (maxHeight * t).clamp(0.0, maxHeight);
    final contentHeight =
        visibleHeight.clamp(maxHeight * QueueSheetController.partPosition,
            maxHeight);

    return Material(
      color: AppColors.background,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: contentHeight,
          maxHeight: contentHeight,
          child: SizedBox(
            height: contentHeight,
            child: Column(
              children: [
                // ═══ ШАПКА: ручка + текущий трек + кнопки + Queue/songs ═══
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) =>
                      controller.drag(d.primaryDelta ?? 0, maxHeight),
                  onVerticalDragEnd: (d) => controller.settle(
                    d.primaryVelocity ?? 0,
                    fromButton: false,
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(top: topPad),
                    child: _Header(
                      player: player,
                      controller: controller,
                      songCount: 0, // обновится внутри через StreamBuilder
                    ),
                  ),
                ),
                // ═══ СПИСОК с кастомной физикой для закрытия вверху ═══
                Expanded(
                  child: _QueueList(
                    controller: controller,
                    player: player,
                    bottomInset: bottomInset,
                    maxHeight: maxHeight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.player,
    required this.controller,
    required this.songCount,
  });
  final PlayerService player;
  final QueueSheetController controller;
  final int songCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        // Ручка
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.elevatedHi,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 12),

        // Текущий трек + кнопки
        StreamBuilder<MediaItem?>(
          stream: player.mediaItem,
          builder: (context, snap) {
            final item = snap.data;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      if (item != null)
                        Artwork(
                          url: item.artUri?.toString(),
                          size: 56,
                          aspectRatio: artAspectRatio(item),
                          borderRadius: 12,
                          memCacheSize: 128,
                        )
                      else
                        const SizedBox(width: 56, height: 56),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              item?.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              item?.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          if (item == null) return;
                          showAddToPlaylistSheet(context, item.toTrack());
                        },
                        icon: const Icon(
                          Icons.more_vert_rounded,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: _ShuffleButton(player: player),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: _RepeatButton(player: player),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 8),

        // ═══ Queue / X songs — в шапке, над списком ═══
        StreamBuilder<List<MediaItem>>(
          stream: player.queue,
          builder: (context, snap) {
            final count = snap.data?.length ?? 0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Queue',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '$count songs',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ShuffleButton extends StatelessWidget {
  const _ShuffleButton({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.elevated,
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(32),
        bottomLeft: Radius.circular(32),
        topRight: Radius.circular(5),
        bottomRight: Radius.circular(5),
      ),
      child: InkWell(
        onTap: () => player.shuffleQueue(),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          bottomLeft: Radius.circular(32),
          topRight: Radius.circular(5),
          bottomRight: Radius.circular(5),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.shuffle_rounded,
                color: AppColors.textPrimary,
                size: 24,
              ),
              SizedBox(width: 12),
              Text(
                'Shuffle',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LoopMode>(
      stream: player.loopModeStream,
      initialData: player.loopMode,
      builder: (context, snap) {
        final mode = snap.data ?? LoopMode.off;
        final isActive = mode != LoopMode.off;

        final borderRadius = isActive
            ? BorderRadius.circular(32)
            : const BorderRadius.only(
                topLeft: Radius.circular(5),
                bottomLeft: Radius.circular(5),
                topRight: Radius.circular(32),
                bottomRight: Radius.circular(32),
              );

        return Material(
          color: AppColors.elevated,
          borderRadius: borderRadius,
          child: InkWell(
            onTap: player.cycleLoopMode,
            borderRadius: borderRadius,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    mode == LoopMode.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    color: isActive
                        ? AppColors.textPrimary
                        : AppColors.textPrimary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Repeat',
                    style: TextStyle(
                      color: isActive
                          ? AppColors.textPrimary
                          : AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QueueList extends StatefulWidget {
  const _QueueList({
    required this.controller,
    required this.player,
    required this.bottomInset,
    required this.maxHeight,
  });

  final QueueSheetController controller;
  final PlayerService player;
  final double bottomInset;
  final double maxHeight;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: widget.player.queue,
      builder: (context, qSnap) {
        final all = qSnap.data ?? const <MediaItem>[];
        return StreamBuilder<int>(
          stream: widget.player.currentIndexStream,
          initialData: widget.player.currentIndex,
          builder: (context, iSnap) {
            final current = iSnap.data ?? -1;

            if (all.isEmpty) {
              return const Center(
                child: Text(
                  'Queue is empty',
                  style: TextStyle(color: Color(0xFF9E8E8E)),
                ),
              );
            }

            final visible = <MapEntry<int, MediaItem>>[
              for (var i = 0; i < all.length; i++) MapEntry(i, all[i]),
            ];

            return ClipRect(
              child: ReorderableListView.builder(
                padding: EdgeInsets.only(
                  top: 2,
                  bottom: 24 + widget.bottomInset,
                ),
                buildDefaultDragHandles: false,
                itemCount: visible.length,
                onReorder: (oldLocal, newLocal) {
                  if (newLocal > oldLocal) newLocal -= 1;
                  final from = visible[oldLocal].key;
                  final to = visible[newLocal].key;
                  widget.player.reorderQueueItem(from, to);
                },
                itemBuilder: (context, localIndex) {
                  final entry = visible[localIndex];
                  final realIndex = entry.key;
                  final m = entry.value;
                  final isCurrent = realIndex == current;
                  return _QueueTile(
                    key: ValueKey('${m.id}_$realIndex'),
                    index: localIndex,
                    media: m,
                    isHighlighted: isCurrent,
                    onTap: () => widget.player.skipToQueueItem(realIndex),
                  );
                },
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) {
                      return ClipRect(
                        child: Material(
                          elevation: 6,
                          color: Colors.transparent,
                          child: child,
                        ),
                      );
                    },
                    child: child,
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.index,
    required this.media,
    required this.onTap,
    this.isHighlighted = false,
  });

  final int index;
  final MediaItem media;
  final VoidCallback onTap;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: isHighlighted
          ? const EdgeInsets.symmetric(horizontal: 8)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: isHighlighted ? AppColors.elevatedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: () {
          showAddToPlaylistSheet(context, media.toTrack());
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isHighlighted ? 8 : 16,
            vertical: 8,
          ),
          child: Row(
            children: [
              Artwork(
                url: media.artUri?.toString(),
                size: 48,
                aspectRatio: artAspectRatio(media),
                borderRadius: 8,
                memCacheSize: 108,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      media.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      media.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Icon(
                        Icons.drag_handle,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDuration(media.duration),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}