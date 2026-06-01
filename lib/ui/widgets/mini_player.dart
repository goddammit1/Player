import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../pages/player_page.dart';

/// Компактная панель в низу экрана со сведениями о текущем треке.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) return const SizedBox.shrink();

        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerPage()),
            ),
            // SafeArea(top: false) добавляет нижний padding, равный
            // высоте системной навигации (gesture bar / 3-button bar).
            // Без него мини-плеер визуально оказывается за кнопками
            // навигации, и контролы не докликиваются.
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 64,
                child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: item.artUri != null
                        ? CachedNetworkImage(
                            imageUrl: item.artUri.toString(),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            // Тихий фоллбэк — без него 404 от img.youtube.com
                            // улетают как Unhandled Exception в логах.
                            errorWidget: (_, __, ___) => Container(
                              width: 56,
                              height: 56,
                              color: Colors.grey,
                              child: const Icon(Icons.music_note),
                            ),
                          )
                        : Container(
                            width: 56,
                            height: 56,
                            color: Colors.grey,
                            child: const Icon(Icons.music_note),
                          ),
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
                              fontWeight: FontWeight.w600),
                        ),
                        Text(
                          item.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<PlaybackState>(
                    stream: player.playbackState,
                    builder: (context, snap) {
                      final st = snap.data;
                      final loading = st != null &&
                          (st.processingState ==
                                  AudioProcessingState.loading ||
                              st.processingState ==
                                  AudioProcessingState.buffering);
                      if (loading) {
                        return const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      final playing = st?.playing ?? false;
                      return IconButton(
                        icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () =>
                            playing ? player.pause() : player.play(),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: player.skipToNext,
                  ),
                ],
              ),
              ),
            ),
          ),
        );
      },
    );
  }
}
