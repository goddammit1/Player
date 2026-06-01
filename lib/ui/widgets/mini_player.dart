import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../pages/player_page.dart';
import 'artwork.dart';

/// Мини-плеер: горизонтальная плашка у самого низа экрана.
///
/// Особенности:
/// - **Прогресс** рисуется не отдельным ползунком, а полупрозрачной
///   заливкой слева направо поверх фона плашки (см. [_ProgressFill]).
///   Заливка строго ограничена самой плашкой за счёт того, что
///   `Stack` живёт внутри SizedBox(height: ...) c фиксированной
///   высотой — без `Positioned.fill` ничто не выйдет за её пределы.
/// - На клик открывается полноэкранный PlayerPage.
/// - Виден только когда есть активный трек.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  static const double _height = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();

        return Material(
          color: AppColors.surface,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerPage()),
            ),
            child: SizedBox(
              height: _height,
              child: Stack(
                children: [
                  // Прогресс-заливка строго внутри плашки — её Stack
                  // ограничен по высоте через SizedBox выше.
                  _ProgressFill(player: player, item: item),
                  // Контент поверх.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Artwork(
                          url: item.artUri?.toString(),
                          size: 44,
                          borderRadius: 8,
                          memCacheSize: 112,
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
                                  fontWeight: FontWeight.w600,
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
                                  fontSize: 11,
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
        );
      },
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
                  color: Colors.white.withValues(alpha: 0.06),
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
