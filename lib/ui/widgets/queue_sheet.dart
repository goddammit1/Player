import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/player_service.dart';
import '../../main.dart' show AppColors;
import 'artwork.dart';

/// Контроллер 2-позиционного окна очереди.
///
/// Окно имеет три «магнитные» позиции (значение [value] = доля высоты
/// экрана, которую занимает окно):
/// - 0.0  — закрыто (за нижним краем экрана);
/// - [QueueSheetController.partPosition] (≈0.5) — Part queue (полэкрана);
/// - 1.0  — Full queue (весь экран).
///
/// Part queue — это просто промежуточная позиция того же окна.
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

  /// Доля экрана для позиции Part queue. Подобрана так, чтобы над
  /// системной навигацией помещались шапка + 5 ближайших треков.
  static const double partPosition = 0.62;

  /// Порог при drag с Queue button: если окно доведено выше этого
  /// значения — сразу уезжаем в Full, минуя остановку на Part.
  static const double fullThreshold = 0.82;

  double get value => _anim.value;
  bool get isClosed => _anim.value <= 0.001;
  bool get isFull => _anim.value >= 0.999;

  /// Открыть в Part queue (анимация выезда снизу ~0.5 сек).
  void openPart() => _anim.animateTo(
        partPosition,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );

  void openFull() => _anim.animateTo(
        1,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );

  void close() => _anim.animateTo(
        0,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );

  /// Мгновенно сдвинуть окно (используется при drag — окно тянется
  /// за пальцем в реальном времени). [delta] — пройденный по вертикали
  /// путь в пикселях (положительный вниз), [maxHeight] — высота экрана.
  void drag(double delta, double maxHeight) {
    if (maxHeight <= 0) return;
    _anim.value = (_anim.value - delta / maxHeight).clamp(0.0, 1.0);
  }

  /// Решает, к какой позиции «примагнититься» после отпускания.
  /// [velocity] — вертикальная скорость в px/s (отрицательная вверх).
  /// [fromButton] — drag начат с Queue button (тогда работает правило
  /// «выше 70% → сразу Full»).
  void settle(double velocity, {required bool fromButton}) {
    const fling = 700;
    final v = value;

    if (fromButton) {
      // Исключение: при первичном drag с кнопки, если довели > 70% —
      // сразу Full. Иначе — Part (или закрыть при сильном броске вниз).
      if (v >= fullThreshold || velocity < -fling) {
        openFull();
      } else if (velocity > fling && v < partPosition * 0.6) {
        close();
      } else {
        openPart();
      }
      return;
    }

    // Drag уже внутри открытого окна — магнитимся к ближайшей из
    // {0, part, 1} с учётом броска.
    if (velocity < -fling) {
      // Резкий бросок вверх.
      v < partPosition ? openPart() : openFull();
      return;
    }
    if (velocity > fling) {
      // Резкий бросок вниз.
      v > partPosition ? openPart() : close();
      return;
    }
    // Спокойное отпускание — ближайшая позиция.
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

/// Полноэкранный слой окна очереди, который кладётся в [Stack] поверх
/// содержимого плеера. Сам по себе невидим, пока контроллер закрыт.
///
/// Структура (сверху вниз) при открытом окне:
/// - ручка (drag handle) — тянем за неё от Part к Full и обратно;
/// - шапка Part: инфо о текущем треке + Shuffle / Repeat;
/// - список очереди (ReorderableListView) — перетаскивание за полоски
///   справа, тап по треку — переход на него.
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
        if (t <= 0.001) return const SizedBox.shrink();

        // Прозрачность контента: 100% достигается на ~половине пути Part.
        final contentOpacity =
            (t / (QueueSheetController.partPosition / 2)).clamp(0.0, 1.0);
        // Затемнение фона за окном растёт вместе с t.
        final scrimOpacity = (t / QueueSheetController.partPosition * 0.5)
            .clamp(0.0, 0.5);

        // Окно ВСЕГДА отрисовано на полную высоту экрана: шапка (ручка +
        // трек + shuffle/repeat) закреплена сверху, под ней — скроллящийся
        // список. Само окно «выезжает» снизу через Transform.translate:
        // при t=1 оно на месте, при t→0 уведено вниз за край экрана.
        // Так шапка ВСЕГДА на верхней кромке окна и видна и в Part, и в
        // Full, а скроллится только список под ней.
        final slideOffset = (1 - t) * maxHeight;

        return Positioned.fill(
          child: Stack(
            children: [
              // Затемнение — тап по нему закрывает окно.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: controller.close,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: scrimOpacity),
                  ),
                ),
              ),
              // Окно на полную высоту, сдвинуто вниз на slideOffset.
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
    // По мере приближения к Full добавляем верхний отступ под статус-бар
    // (и системную шторку уведомлений), чтобы шапка/ручка не уезжали под
    // них. Отступ появляется только ближе к Full, чтобы в Part окно
    // оставалось «вплотную».
    final fullProgress =
        ((t - QueueSheetController.partPosition) /
                (1 - QueueSheetController.partPosition))
            .clamp(0.0, 1.0);
    final topPad = topInset * fullProgress;

    return Material(
      color: AppColors.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      // Окно физически на полную высоту экрана и сдвинуто вниз, поэтому
      // ВИДИМАЯ часть окна = maxHeight * t. Ограничиваем высоту контента
      // этой видимой частью (ConstrainedBox + mainAxisSize.min). Тогда
      // шапка остаётся закреплённой на верхней кромке окна, а список
      // (Flexible) занимает только остаток видимой зоны и листается прямо
      // в окошке Part queue. Нижняя «невидимая» часть окна (за краем
      // экрана) контентом не заполняется, поэтому overflow нет.
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight * t),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ручка сверху + шапка — за них тянем окно (Part <-> Full).
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
                  child: _Header(player: player, controller: controller),
                ),
              ),
              // Список очереди — листается; reorder за полоски справа.
              // Flexible отдаёт списку остаток видимой высоты окна.
              Flexible(
                child: _QueueList(
                  player: player,
                  bottomInset: bottomInset,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.player, required this.controller});
  final PlayerService player;
  final QueueSheetController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        // Drag handle.
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.elevatedHi,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 14),
        // Инфо о текущем треке + быстрый доступ к shuffle/repeat.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 12, 14),
          child: StreamBuilder<MediaItem?>(
            stream: player.mediaItem,
            builder: (context, snap) {
              final item = snap.data;
              return Row(
                children: [
                  Artwork(
                    url: item?.artUri?.toString(),
                    size: 48,
                    borderRadius: 10,
                    memCacheSize: 112,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Now playing',
                          style: TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item?.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          item?.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ShuffleButton(player: player),
                  const SizedBox(width: 4),
                  _RepeatButton(player: player),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1, color: AppColors.outline),
      ],
    );
  }
}

class _ShuffleButton extends StatelessWidget {
  const _ShuffleButton({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    // Shuffle — разовое действие (перемешать очередь), а не режим:
    // не подсвечивается, просто нажимается и выполняет функцию.
    return IconButton(
      onPressed: () => player.shuffleQueue(),
      icon: const Icon(
        Icons.shuffle_rounded,
        color: AppColors.textSecondary,
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
        return IconButton(
          onPressed: player.cycleLoopMode,
          icon: Icon(
            mode == LoopMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: mode == LoopMode.off
                ? AppColors.textSecondary
                : Colors.lightGreenAccent,
          ),
        );
      },
    );
  }
}

class _QueueList extends StatelessWidget {
  const _QueueList({
    required this.player,
    required this.bottomInset,
  });
  final PlayerService player;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: player.queue,
      builder: (context, qSnap) {
        final all = qSnap.data ?? const <MediaItem>[];
        return StreamBuilder<int>(
          stream: player.currentIndexStream,
          initialData: player.currentIndex,
          builder: (context, iSnap) {
            final current = iSnap.data ?? -1;

            if (all.isEmpty) {
              return const Center(
                child: Text(
                  'Queue is empty',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              );
            }

            // Список всегда содержит все треки после текущего. В Part
            // queue видны только те, что помещаются в видимую зону окна
            // (≈5), остальные доступны прокруткой прямо в этом окошке. По
            // мере растягивания окна к Full видимая зона растёт и треков
            // видно больше равномерно, без пустой зоны после пятого.
            final start = current >= 0 ? current + 1 : 0;
            final visible = <MapEntry<int, MediaItem>>[
              for (var i = start; i < all.length; i++) MapEntry(i, all[i]),
            ];

            return ReorderableListView.builder(
              // Нижний отступ учитывает системную навигацию, чтобы
              // последний трек не прятался под неё.
              padding: EdgeInsets.only(top: 6, bottom: 24 + bottomInset),
              buildDefaultDragHandles: false,
              itemCount: visible.length,
              onReorder: (oldLocal, newLocal) {
                if (newLocal > oldLocal) newLocal -= 1;
                final from = visible[oldLocal].key;
                final to = visible[newLocal].key;
                player.reorderQueueItem(from, to);
              },
              itemBuilder: (context, localIndex) {
                final entry = visible[localIndex];
                final realIndex = entry.key;
                final m = entry.value;
                return _QueueTile(
                  key: ValueKey('${m.id}_$realIndex'),
                  index: localIndex,
                  media: m,
                  onTap: () => player.skipToQueueItem(realIndex),
                );
              },
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
  });

  final int index;
  final MediaItem media;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Artwork(
                url: media.artUri?.toString(),
                size: 44,
                borderRadius: 8,
                memCacheSize: 100,
              ),
              const SizedBox(width: 12),
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
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      media.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Две полоски справа — за них перетаскиваем трек.
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
