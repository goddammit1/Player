import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:marquee/marquee.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/player_service.dart';
import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../../models/track.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/snack.dart';

/// Полноэкранный плеер.
///
/// Структура (сверху вниз):
/// 1. Top bar: `chevron_down` слева, three-dots справа.
/// 2. Квадратная обложка трека ~85% ширины с большим радиусом.
/// 3. Название + исполнитель.
/// 4. Кастомный прогресс-бар + времена.
/// 5. Контролы: круг prev — pill play — круг next.
/// 6. Bottom action bar: repeat — pill queue — three-dots.
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(child: PlayerContent()),
    );
  }
}

/// Содержимое полноэкранного плеера без [Scaffold]/[SafeArea].
///
/// Вынесено в отдельный виджет, чтобы переиспользовать как в
/// самостоятельном маршруте [PlayerPage], так и внутри
/// выезжающего снизу `NowPlayingOverlay`.
///
/// [onClose] — если задан, вызывается по нажатию кнопки «вниз»
/// (используется оверлеем, чтобы свернуть плеер вместо `Navigator.pop`).
class PlayerContent extends ConsumerWidget {
  const PlayerContent({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) {
          return const Center(
            child: Text(
              'No track',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            children: [
              _TopBar(item: item, onClose: onClose),
              const SizedBox(height: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LayoutBuilder(
                      builder: (_, c) {
                        final size = c.maxWidth.clamp(0, 420.0).toDouble();
                        return Artwork(
                          url: item.artUri?.toString(),
                          size: size,
                          borderRadius: 28,
                          memCacheSize: 800,
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    _TitleScroller(text: item.title),
                    const SizedBox(height: 6),
                    Text(
                      item.artist ?? '',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              _Controls(player: player),
              const SizedBox(height: 16),
              _ProgressBar(player: player, fallbackDuration: item.duration),
              const SizedBox(height: 24),
              _BottomActions(player: player, item: item),
            ],
          ),
        );
      },
    );
  }
}


// =====================================================================
//  TOP BAR
// =====================================================================

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.item, this.onClose});
  final MediaItem item;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Material(
          color: AppColors.elevated,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onClose ?? () => Navigator.of(context).pop(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),

        const Spacer(),
        Material(
          color: AppColors.elevated,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _showMore(context, ref, item),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.more_horiz_rounded,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showMore(BuildContext context, WidgetRef ref, MediaItem item) {
    final track = _trackFromMedia(item);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (track != null) {
                    showAddToPlaylistSheet(context, track);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showSnack(context, 'Share — coming soon');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Восстановить Track из MediaItem (нам нужно для add-to-playlist).
  /// Используем поля + extras: `sourceId` мы туда положили в
  /// PlayerService._toMediaItem.
  Track? _trackFromMedia(MediaItem m) {
    final sourceId = m.extras?['sourceId'] as String?;
    final trackId = m.extras?['trackId'] as String?;
    if (sourceId == null || trackId == null) return null;
    return Track(
      id: trackId,
      sourceId: sourceId,
      title: m.title,
      artist: m.artist ?? '',
      duration: m.duration,
      artworkUrl: m.artUri?.toString(),
    );
  }
}

// =====================================================================
//  CONTROLS
// =====================================================================

class _Controls extends StatelessWidget {
  const _Controls({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    return Row(
      // Раздаём 3 элемента по строке с одинаковыми отступами — это
      // выглядит симметрично и не зависит от ширины центральной pill.
      children: [
        _RoundButton(
          icon: Icons.skip_previous_rounded,
          onTap: player.skipToPrevious,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StreamBuilder<PlaybackState>(
            stream: player.playbackState,
            builder: (context, snap) {
              final st = snap.data;
              final loading = st != null &&
                  (st.processingState == AudioProcessingState.loading ||
                      st.processingState == AudioProcessingState.buffering);
              final playing = st?.playing ?? false;
              return Material(
                color: AppColors.elevatedHi,
                borderRadius: BorderRadius.circular(32),
                child: InkWell(
                  borderRadius: BorderRadius.circular(32),
                  onTap: () => playing ? player.pause() : player.play(),
                  child: SizedBox(
                    height: 64,
                    child: Center(
                      child: loading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: AppColors.textPrimary,
                              ),
                            )
                          : Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: AppColors.textPrimary,
                              size: 36,
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        _RoundButton(
          icon: Icons.skip_next_rounded,
          onTap: player.skipToNext,
        ),
      ],
    );
  }
}

/// Заголовок текущего трека: если влезает в одну строку — обычный
/// Text, иначе бегущая строка через `marquee`. Это удобнее, чем
/// двухстрочный с ellipsis: пользователь успевает прочитать всё.
class _TitleScroller extends StatelessWidget {
  const _TitleScroller({required this.text});
  final String text;

  static const TextStyle _style = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: LayoutBuilder(
        builder: (_, c) {
          // Заранее меряем ширину текста — если влезает, marquee не
          // нужен и тратить кадры на анимацию незачем.
          final tp = TextPainter(
            text: TextSpan(text: text, style: _style),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          if (tp.width <= c.maxWidth) {
            return Center(
              child: Text(
                text,
                maxLines: 1,
                style: _style,
              ),
            );
          }
          return Marquee(
            text: text,
            style: _style,
            scrollAxis: Axis.horizontal,
            blankSpace: 60,
            velocity: 30,
            pauseAfterRound: const Duration(seconds: 2),
            startPadding: 0,
            accelerationDuration: const Duration(milliseconds: 400),
            accelerationCurve: Curves.easeOut,
            decelerationDuration: const Duration(milliseconds: 400),
            decelerationCurve: Curves.easeIn,
            fadingEdgeStartFraction: 0.06,
            fadingEdgeEndFraction: 0.06,
          );
        },
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: AppColors.textPrimary, size: 28),
        ),
      ),
    );
  }
}

// =====================================================================
//  PROGRESS BAR
// =====================================================================

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.player, this.fallbackDuration});
  final PlayerService player;
  final Duration? fallbackDuration;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  /// Когда пользователь тянет ползунок — показываем эту позицию вместо
  /// реальной из стрима, иначе UI «дёргается».
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    // Тротлим до ~25 fps. Достаточно плавно, экономит CPU.
    final pos = (widget.player.positionStream)
        .throttleTime(const Duration(milliseconds: 40));

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
                        setState(() {
                          _dragFraction = (d.localPosition.dx / width)
                              .clamp(0.0, 1.0);
                        });
                      },
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _dragFraction = (d.localPosition.dx / width)
                              .clamp(0.0, 1.0);
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        if (_dragFraction != null && maxMs > 0) {
                          widget.player.seek(
                            Duration(
                              milliseconds: (_dragFraction! * maxMs).round(),
                            ),
                          );
                        }
                        setState(() => _dragFraction = null);
                      },
                      onTapDown: (d) {
                        final frac =
                            (d.localPosition.dx / width).clamp(0.0, 1.0);
                        if (maxMs > 0) {
                          widget.player.seek(
                            Duration(
                              milliseconds: (frac * maxMs).round(),
                            ),
                          );
                        }
                      },
                      child: CustomPaint(
                        size: const Size(double.infinity, 14),
                        painter: _ProgressPainter(fraction: f),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(maxMs > 0
                          ? Duration(milliseconds: (f * maxMs).round())
                          : position),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      _fmt(duration),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
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

/// Толстая горизонтальная линия трека + прямоугольный «карандашный»
/// бегунок, делящий полосу в позиции [fraction] (0..1). Линия скруглена.
class _ProgressPainter extends CustomPainter {
  _ProgressPainter({required this.fraction});
  final double fraction;

  static const _trackHeight = 6.0;
  static const _thumbWidth = 4.0;
  static const _thumbHeight = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;

    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        0,
        centerY - _trackHeight / 2,
        size.width,
        _trackHeight,
      ),
      const Radius.circular(3),
    );
    final trackPaint = Paint()..color = AppColors.elevated;
    canvas.drawRRect(trackRect, trackPaint);

    // Заполненная часть слева от бегунка чуть светлее.
    final filledW = size.width * fraction.clamp(0.0, 1.0);
    if (filledW > 0) {
      final filledRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          centerY - _trackHeight / 2,
          filledW,
          _trackHeight,
        ),
        const Radius.circular(3),
      );
      // Контрастный белый цвет — заметная заливка слева от бегунка.
      final filledPaint = Paint()..color = AppColors.textPrimary;
      canvas.drawRRect(filledRect, filledPaint);
    }

    final thumbX = (filledW - _thumbWidth / 2).clamp(0.0, size.width - _thumbWidth);
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(thumbX, centerY - _thumbHeight / 2, _thumbWidth, _thumbHeight),
      const Radius.circular(2),
    );
    final thumbPaint = Paint()..color = AppColors.textPrimary;
    canvas.drawRRect(thumbRect, thumbPaint);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) => old.fraction != fraction;
}

// =====================================================================
//  BOTTOM ACTION BAR
// =====================================================================

class _BottomActions extends StatefulWidget {
  const _BottomActions({required this.player, required this.item});
  final PlayerService player;
  final MediaItem item;

  @override
  State<_BottomActions> createState() => _BottomActionsState();
}

class _BottomActionsState extends State<_BottomActions> {
  // Локальный UI-стейт цикла повтора. На плеер он пока не передаётся —
  // достаточно подсветки иконки, чтобы UI не выглядел мёртвым.
  LoopMode _loop = LoopMode.off;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SquircleButton(
          icon: _loop == LoopMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          highlighted: _loop != LoopMode.off,
          onTap: _cycleLoop,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Material(
            color: AppColors.elevated,
            borderRadius: BorderRadius.circular(28),
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: () => _showQueue(context),
              child: const SizedBox(
                height: 56,
                child: Center(
                  child: Icon(
                    Icons.queue_music_rounded,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        _SquircleButton(
          icon: Icons.more_horiz_rounded,
          onTap: () => _showExtra(context),
          shape: BoxShape.circle,
        ),
      ],
    );
  }

  void _cycleLoop() {
    final next = switch (_loop) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    widget.player.rawPlayer.setLoopMode(next);
    setState(() => _loop = next);
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: StreamBuilder<List<MediaItem>>(
              stream: widget.player.queue,
              builder: (context, snap) {
                final list = snap.data ?? const <MediaItem>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                      child: Text(
                        'Queue',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final m = list[i];
                          return ListTile(
                            leading: Artwork(
                              url: m.artUri?.toString(),
                              size: 44,
                              borderRadius: 8,
                            ),
                            title: Text(
                              m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              m.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () {
                              widget.player.skipToQueueItem(i);
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (track.sourceId.isNotEmpty) {
                    showAddToPlaylistSheet(context, track);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showSnack(context, 'Share — coming soon');
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SquircleButton extends StatelessWidget {
  const _SquircleButton({
    required this.icon,
    required this.onTap,
    this.highlighted = false,
    this.shape = BoxShape.rectangle,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return Material(
      color: AppColors.elevated,
      shape: shape == BoxShape.circle
          ? const CircleBorder()
          : RoundedRectangleBorder(borderRadius: radius),
      child: InkWell(
        customBorder: shape == BoxShape.circle
            ? const CircleBorder()
            : RoundedRectangleBorder(borderRadius: radius),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(
            icon,
            color: highlighted ? Colors.lightGreenAccent : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
