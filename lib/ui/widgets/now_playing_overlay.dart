import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../pages/player_page.dart';
import 'artwork.dart';
import '../../core/artwork_helper.dart';

/// Выезжающий снизу плеер «Now playing».
///
/// Идея: единая панель, прижатая к низу экрана, которую можно тянуть
/// пальцем вверх. По мере вытягивания она плавно превращается из узкой
/// мини-плашки в полноэкранный плеер — высота, отступы и непрозрачность
/// контента интерполируются по значению [_t] (0 = мини, 1 = развёрнуто).
///
/// Жесты:
/// - Вертикальный drag по панели тянет её **за пальцем** в реальном
///   времени (свойство `t` меняется на каждый `onVerticalDragUpdate`).
/// - При отпускании панель «доезжает» до ближайшего состояния (вверх или
///   вниз) с учётом скорости броска (fling).
/// - Тап по свёрнутой плашке разворачивает её на весь экран.
///
/// Фильтрация системных жестов:
/// - Мёртвая зона 40px от нижнего края экрана — drag оттуда игнорируется.
/// - Слишком быстрые короткие свайпы (>2500 px/s при дистанции <60 px)
///   интерпретируются как системный жест «назад/домой» и игнорируются.
///
/// Виден только когда есть активный трек (mediaItem != null).
class NowPlayingOverlay extends ConsumerStatefulWidget {
  const NowPlayingOverlay({super.key});

  /// Высота свёрнутой мини-плашки (без учёта системного отступа снизу).
  static const double miniHeight = 80;

  @override
  ConsumerState<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends ConsumerState<NowPlayingOverlay>
    with SingleTickerProviderStateMixin {
  /// 0.0 — свёрнут (мини), 1.0 — развёрнут (полный экран).
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 0,
  );

  /// Полная высота экрана — кэшируем в `build` для расчёта drag-дельты.
  double _maxHeight = 0;

  // ===== Фильтрация системных жестов =====
  /// Y-координата начала drag (глобальная).
  double _dragStartY = 0;
  /// Пройденная дистанция drag (аккумулируется).
  double _dragDistance = 0;
  /// Флаг: drag начался в мёртвой зоне — полностью игнорируем.
  bool _dragFromDeadZone = false;

  static const double _bottomDeadZone = 40;      // px от низа экрана
  static const double _maxSystemVelocity = 2500; // px/s — порог системного свайпа
  static const double _minUserDistance = 60;       // px — минимальная дистанция пользовательского drag

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
  void _expand() {
  FocusManager.instance.primaryFocus?.unfocus();  // ← убираем фокус со всех полей
  _ctrl.animateTo(1, curve: Curves.easeOutCubic);
  }
  void _collapse() => _ctrl.animateTo(0, curve: Curves.easeOutCubic);

  void _onDragStart(DragStartDetails d) {
    _dragStartY = d.globalPosition.dy;
    _dragDistance = 0;
    _dragFromDeadZone = _dragStartY > _maxHeight - _bottomDeadZone;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_maxHeight <= 0) return;

    // Полностью игнорируем drag, начатый из мёртвой зоны снизу.
    if (_dragFromDeadZone) return;

    final delta = d.primaryDelta!;
    _dragDistance += delta.abs();
    // Тянем вверх -> t увеличивается. dy<0 при движении вверх.
    _ctrl.value -= delta / _maxHeight;
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0; // px/s: <0 вверх, >0 вниз.

    // Если drag начался из мёртвой зоны — полностью игнорируем.
    if (_dragFromDeadZone) {
      _dragFromDeadZone = false;
      return;
    }

    // Если свайп слишком быстрый и короткий — скорее всего системный
    // жест (сворачивание приложения / назад). Игнорируем.
    final isSystemGesture =
        v.abs() > _maxSystemVelocity && _dragDistance < _minUserDistance;
    if (isSystemGesture) return;

    const flingThreshold = 600;
    if (v < -flingThreshold) {
      _expand();
    } else if (v > flingThreshold) {
      _collapse();
    } else {
      // Решаем по тому, ближе ли панель к развёрнутому состоянию.
      _ctrl.value > 0.5 ? _expand() : _collapse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    final media = MediaQuery.of(context);
    _maxHeight = media.size.height;
    final bottomInset = media.padding.bottom;

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();

        return AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value.clamp(0.0, 1.0);

            final miniOpacity = (1 - t / 0.55).clamp(0.0, 1.0);
            final fullOpacity = ((t - 0.15) / 0.5).clamp(0.0, 1.0);
            final collapsedBottom =
                NowPlayingOverlay.miniHeight + bottomInset;
            final slideOffset = (1 - t) * (_maxHeight - collapsedBottom);

            return Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, slideOffset),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: _onDragEnd,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Большой плеер — фон + контент, на весь экран.
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: t < 0.9,
                          child: Opacity(
                            opacity: fullOpacity,
                            child: ColoredBox(
                              color: AppColors.background,
                              child: SafeArea(
                                child: PlayerContent(onClose: _collapse),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Мини-плашка — верхняя полоса этого же блока.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: NowPlayingOverlay.miniHeight + 8,
                        child: IgnorePointer(
                          ignoring: t > 0.1,
                          child: Opacity(
                            opacity: miniOpacity,
                            child: _MiniBar(
                              player: player,
                              item: item,
                              onTap: _expand,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Свёрнутая мини-плашка: обложка, название/исполнитель, play/pause, next.
/// Поверх фона рисуется тонкая прогресс-заливка слева направо.
class _MiniBar extends StatelessWidget {
  const _MiniBar({
    required this.player,
    required this.item,
    required this.onTap,
  });

  final dynamic player;
  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: NowPlayingOverlay.miniHeight,
            child: Stack(
              children: [
                _ProgressFill(player: player, item: item),
                Padding(
                  padding: const EdgeInsets.fromLTRB(5, 0, 10, 0),
                  child: Row(
                    children: [
                      Artwork(
                        url: item.artUri?.toString(),
                        size: 54,
                        borderRadius: 11,
                        memCacheSize: 112,
                        aspectRatio: artAspectRatio(item),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w600,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _PlayPauseButton(player: player),
                      IconButton(
                        icon: const Icon(
                          Icons.skip_next_rounded,
                          color: AppColors.textPrimary,
                        ),
                        onPressed: player.skipToNext,
                      ),
                    ],
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

class _ProgressFill extends StatelessWidget {
  const _ProgressFill({required this.player, required this.item});
  final dynamic player;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final positionThrottled = (player.positionStream as Stream<Duration>)
        .throttleTime(const Duration(milliseconds: 100));

    return StreamBuilder<Duration>(
      stream: positionThrottled,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: player.durationStream as Stream<Duration?>,
          builder: (context, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? item.duration ?? Duration.zero;
            final f = dur.inMilliseconds > 0
                ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: f,
                heightFactor: 1,
                child: Container(
                  color: AppColors.surfaceProgressBar,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.player});
  final dynamic player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState as Stream<PlaybackState>,
      builder: (context, snap) {
        final st = snap.data;
        final loading = st != null &&
            (st.processingState == AudioProcessingState.loading ||
                st.processingState == AudioProcessingState.buffering);
        if (loading) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final playing = st?.playing ?? false;
        return IconButton(
          icon: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: AppColors.textPrimary,
          ),
          onPressed: () => playing ? player.pause() : player.play(),
        );
      },
    );
  }
}
