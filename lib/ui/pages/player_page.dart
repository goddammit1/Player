import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:marquee/marquee.dart';
import 'package:rxdart/rxdart.dart';

import 'dart:ui'; // для lerpDouble

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
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            children: [
              // Пустое пространство сверху — толкает всё вниз к центру
              Expanded(child: SizedBox.shrink()),
              
              // Обложка без Expanded — занимает ровно свой размер
              LayoutBuilder(
                builder: (_, c) {
                  final size = c.maxWidth.clamp(0, 420.0).toDouble();
                  return Artwork(
                    url: item.artUri?.toString(),
                    size: size,
                    borderRadius: 10,
                    memCacheSize: 800,
                  );
                },
              ),
              
              const SizedBox(height: 40),
              _TitleScroller(text: item.title),
              const SizedBox(height: 10),
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
              const SizedBox(height: 40),


              _Controls(player: player),
              const SizedBox(height: 15),
              _ProgressBar(player: player, fallbackDuration: item.duration),
              const SizedBox(height: 20),
              _BottomActions(player: player, item: item),
              
              // Пустое пространство снизу — балансирует верхний Expanded
              //Expanded(child: SizedBox.shrink()),
            ],
          ),
        );
      },
    );
  }
}

// =====================================================================
//  CONTROLS
// =====================================================================


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

class _Controls extends StatefulWidget {
  const _Controls({required this.player});
  final PlayerService player;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> with TickerProviderStateMixin {
  late final AnimationController _playAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    value: 0,
  );
  
  late final AnimationController _prevAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );
  
  late final AnimationController _nextAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );
  
  bool _isPlayPressed = false;
  bool _isPrevPressed = false;
  bool _isNextPressed = false;

  @override
  void dispose() {
    _playAnim.dispose();
    _prevAnim.dispose();
    _nextAnim.dispose();
    super.dispose();
  }

  void _onPlayPointerDown(PointerDownEvent event) {
    if (!_isPlayPressed) {
      _isPlayPressed = true;
      _playAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPlayPointerUp(PointerUpEvent event) => _onPlayRelease();
  void _onPlayPointerCancel(PointerCancelEvent event) => _onPlayRelease();

  void _onPlayRelease() {
    if (_isPlayPressed) {
      _isPlayPressed = false;
      _playAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCirc,
      );
    }
  }

  void _onPrevPointerDown(PointerDownEvent event) {
    if (!_isPrevPressed) {
      _isPrevPressed = true;
      _prevAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPrevPointerUp(PointerUpEvent event) => _onPrevRelease();
  void _onPrevPointerCancel(PointerCancelEvent event) => _onPrevRelease();

  void _onPrevRelease() {
    if (_isPrevPressed) {
      _isPrevPressed = false;
      _prevAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCirc,
      );
    }
  }

  void _onNextPointerDown(PointerDownEvent event) {
    if (!_isNextPressed) {
      _isNextPressed = true;
      _nextAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onNextPointerUp(PointerUpEvent event) => _onNextRelease();
  void _onNextPointerCancel(PointerCancelEvent event) => _onNextRelease();

  void _onNextRelease() {
    if (_isNextPressed) {
      _isNextPressed = false;
      _nextAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCirc,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.player.playbackState,
      builder: (context, snap) {
        final st = snap.data;
        final loading = st != null &&
            (st.processingState == AudioProcessingState.loading ||
                st.processingState == AudioProcessingState.buffering);
        final playing = st?.playing ?? false;

        return AnimatedBuilder(
          animation: Listenable.merge([_playAnim, _prevAnim, _nextAnim]),
          builder: (context, _) {
            final playExpanded = _playAnim.value;
            final prevExpanded = _prevAnim.value;
            final nextExpanded = _nextAnim.value;
            
            // ИСПРАВЛЕНО: prev/next сужаются при нажатии на play
            // Как в Kotlin: if (isPlayPausePressed) 0.35f else 0.45f
            // prevWidth = base - shrink * playExpanded + expand * prevExpanded
            final prevWidth = 56 - 20 * playExpanded + 24 * prevExpanded;
            final nextWidth = 56 - 20 * playExpanded + 24 * nextExpanded;
            final playWidth = 170 + 40 * playExpanded - 30 * (prevExpanded + nextExpanded);
            
            final isPlayPressed = _playAnim.value > 0 || _isPlayPressed;
            final isPrevPressed = _prevAnim.value > 0 || _isPrevPressed;
            final isNextPressed = _nextAnim.value > 0 || _isNextPressed;

            return Row(
              children: [
                const SizedBox(width: 5),
                // Prev — сужается при нажатии на play
                Listener(
                  onPointerDown: _onPrevPointerDown,
                  onPointerUp: _onPrevPointerUp,
                  onPointerCancel: _onPrevPointerCancel,
                  child: GestureDetector(
                    onTap: widget.player.skipToPrevious,
                    child: Material(
                      color: AppColors.elevated,
                      borderRadius: BorderRadius.circular(isPrevPressed ? 32 : 32),
                      child: SizedBox(
                        width: prevWidth,
                        height: 64,
                        child: Icon(
                          Icons.skip_previous_rounded,
                          color: AppColors.textPrimary,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Play/pause — расширяется при нажатии
                                Listener(
                  onPointerDown: _onPlayPointerDown,
                  onPointerUp: _onPlayPointerUp,
                  onPointerCancel: _onPlayPointerCancel,
                  child: GestureDetector(
                    onTap: () => playing ? widget.player.pause() : widget.player.play(),
                    child: Material(
                      color: AppColors.elevatedHi,
                      borderRadius: BorderRadius.circular(
                        playing 
                          ? (isPlayPressed ? 20 : 20)  // Pause: зажат=16, отпущен=20
                          : (isPlayPressed ? 32 : 32), // Play: зажат=32, отпущен=62
                      ),
                      child: SizedBox(
                        width: playWidth,
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
                  ),
                ),
                const SizedBox(width: 10),
                // Next — сужается при нажатии на play
                Listener(
                  onPointerDown: _onNextPointerDown,
                  onPointerUp: _onNextPointerUp,
                  onPointerCancel: _onNextPointerCancel,
                  child: GestureDetector(
                    onTap: widget.player.skipToNext,
                    child: Material(
                      color: AppColors.elevated,
                      borderRadius: BorderRadius.circular(isNextPressed ? 32 : 32),
                      child: SizedBox(
                        width: nextWidth,
                        height: 64,
                        child: Icon(
                          Icons.skip_next_rounded,
                          color: AppColors.textPrimary,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
              ],
            );
          },
        );
      },
    );
  }
}

class _AnimatedSideButton extends StatelessWidget {
  const _AnimatedSideButton({
    required this.icon,
    required this.onTap,
    required this.width,
  });
  final IconData icon;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: SizedBox(
          width: width,
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

class _ProgressBarState extends State<_ProgressBar> 
    with SingleTickerProviderStateMixin {
  /// Когда пользователь тянет ползунок — показываем эту позицию вместо
  /// реальной из стрима, иначе UI «дёргается».

  double? _dragFraction;
  bool _isDragging = false;

  // Анимация thumb
  late final AnimationController _thumbAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 50),
    value: 0, // 0 = нормальный размер, 1 = сжатый
  );

  @override
  void dispose() {
    _thumbAnim.dispose();
    super.dispose();
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
                        _thumbAnim.forward(); // сжимаем
                        setState(() {
                          _isDragging = true;
                          // НЕ меняем _dragFraction здесь — thumb не двигается
                        });
                      },
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _dragFraction = (d.localPosition.dx / width).clamp(0.0, 1.0);
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        _thumbAnim.reverse(); // возвращаем
                        if (_dragFraction != null && maxMs > 0) {
                          widget.player.seek(
                            Duration(milliseconds: (_dragFraction! * maxMs).round()),
                          );
                        }
                        setState(() {
                          _isDragging = false;
                          _dragFraction = null;
                        });
                      },
                      onTapDown: (d) {
                        _thumbAnim.forward(); // сжимаем при касании
                        setState(() {
                          _isDragging = true;
                          // НЕ меняем _dragFraction — thumb остаётся на месте
                        });
                      },
                      onTapUp: (d) {
                        _thumbAnim.reverse(); // возвращаем
                        // Перемещаем thumb к позиции отпускания
                        final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
                        if (maxMs > 0) {
                          widget.player.seek(
                            Duration(milliseconds: (frac * maxMs).round()),
                          );
                        }
                        setState(() {
                          _isDragging = false;
                          _dragFraction = null;
                        });
                      },
                      onTapCancel: () {
                        _thumbAnim.reverse(); // возвращаем
                        setState(() {
                          _isDragging = false;
                          _dragFraction = null;
                        });
                      },
                      child: Container(
                        height: 80,
                        color: Colors.transparent,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Прогресс-бар прижат кверху области
                            Padding(
                              padding: const EdgeInsets.only(top: 30),
                              child: CustomPaint(
                                size: const Size(double.infinity, 14),
                                painter: _ProgressPainter(
                                  fraction: f,
                                  thumbAnim: _thumbAnim,
                                ),
                              ),
                            ),
                            // Время внутри той же области, компактно
                            const SizedBox(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
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
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                // УБРАНО: const SizedBox(height: 6) и Row с временем — они теперь внутри GestureDetector
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
  _ProgressPainter({
    required this.fraction,
    required this.thumbAnim,
  }) : super(repaint: thumbAnim); // <-- автоматическая перерисовка при анимации
  
  final double fraction;
  final Animation<double> thumbAnim;

  static const _trackHeight = 10.0;        // толще трек
  static const _thumbWidthNormal = 8.0;         // шире бегунок
  static const _thumbHeightNormal = 48.0;       // выше бегунок (как на скриншоте)
  static const _thumbHeightDragging = 48.0;
  static const _thumbRadius = 4.0;        // скругление бегунка               
  static const _gapDragging = 6.0;
  static const _gapNormal = 4.0;          // зазор между бегунком и полосками
  static const _thumbWidthDragging = 4.0;
  static const _margin = 16.0;            // отступ слева и справа
  
  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final totalWidth = size.width - _margin * 2;
    final filledW = totalWidth * fraction.clamp(0.0, 1.0);
    
    // Плавная интерполяция через анимацию (0..1)
    final double t = thumbAnim.value;
    
    final double thumbWidth = _thumbWidthNormal + (_thumbWidthDragging - _thumbWidthNormal) * t;
    final double thumbHeight = _thumbHeightNormal + (_thumbHeightDragging - _thumbHeightNormal) * t;
    final double gap = _gapNormal + (_gapDragging - _gapNormal) * t;
    
    // Скругление у thumb: от нормального (2) к сжатому (4)
    final double thumbCornerRadius = 2 + 2 * t;
    
    final double thumbX = _margin + filledW - thumbWidth / 2;
    final double clampedThumbX = thumbX.clamp(_margin, _margin + totalWidth - thumbWidth);

    // Фоновый трек
    if (clampedThumbX + thumbWidth + gap < _margin + totalWidth) {
      final double trackStart = clampedThumbX + thumbWidth + gap;
      final double trackWidth = (_margin + totalWidth) - trackStart;
      
      final trackRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(trackStart, centerY - _trackHeight / 2, trackWidth, _trackHeight),
        topLeft: Radius.circular(thumbCornerRadius),
        topRight: const Radius.circular(_trackHeight / 2),
        bottomLeft: Radius.circular(thumbCornerRadius),
        bottomRight: const Radius.circular(_trackHeight / 2),
      );
      final trackPaint = Paint()..color = AppColors.elevated.withOpacity(0.5);
      canvas.drawRRect(trackRect, trackPaint);
    }

    // Заполненная часть
    if (clampedThumbX > _margin + gap) {
      final double filledWidth = clampedThumbX - gap - _margin;
      
      final filledRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(_margin, centerY - _trackHeight / 2, filledWidth, _trackHeight),
        topLeft: const Radius.circular(_trackHeight / 2),
        topRight: Radius.circular(thumbCornerRadius),
        bottomLeft: const Radius.circular(_trackHeight / 2),
        bottomRight: Radius.circular(thumbCornerRadius),
      );
      final filledPaint = Paint()..color = const Color(0xFF8B8689);
      canvas.drawRRect(filledRect, filledPaint);
    }

    // Бегунок
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(clampedThumbX, centerY - thumbHeight / 2, thumbWidth, thumbHeight),
      const Radius.circular(_thumbRadius),
    );
    final thumbPaint = Paint()..color = const Color(0xFF8B8689);
    canvas.drawRRect(thumbRect, thumbPaint);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) {
    return old.fraction != fraction || old.thumbAnim.value != thumbAnim.value;
  }
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
        const SizedBox(width: 5),
        _SquircleButton(
          icon: _loop == LoopMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          highlighted: _loop != LoopMode.off,
          onTap: _cycleLoop,
        ),
        const SizedBox(width: 10),
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
        const SizedBox(width: 10),
        _SquircleButton(
          icon: Icons.more_horiz_rounded,
          onTap: () => _showExtra(context),
          shape: BoxShape.circle,
        ),
        const SizedBox(width: 5),
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
