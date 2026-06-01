import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

class PlayerPage extends ConsumerWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snapshot) {
          final item = snapshot.data;
          if (item == null) {
            return const Center(child: Text('Нет активного трека'));
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const Spacer(),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: item.artUri != null
                      ? CachedNetworkImage(
                          imageUrl: item.artUri.toString(),
                          width: 320,
                          height: 320,
                          fit: BoxFit.cover,
                          // Тихий фоллбэк, чтобы 404 от img.youtube.com
                          // не валились как Unhandled Exception.
                          errorWidget: (_, __, ___) => Container(
                            width: 320,
                            height: 320,
                            color: Colors.grey,
                            child: const Icon(Icons.music_note, size: 96),
                          ),
                        )
                      : Container(
                          width: 320,
                          height: 320,
                          color: Colors.grey,
                          child: const Icon(Icons.music_note, size: 96),
                        ),
                ),
                const SizedBox(height: 32),
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  item.artist ?? '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                _PositionBar(),
                const SizedBox(height: 16),
                _Controls(),
                const Spacer(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PositionBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: player.durationStream,
          builder: (context, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final maxMs = dur.inMilliseconds.toDouble();
            final value = maxMs > 0
                ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble()
                : 0.0;

            return Column(
              children: [
                Slider(
                  min: 0,
                  max: maxMs > 0 ? maxMs : 1,
                  value: value,
                  onChanged: (v) =>
                      player.seek(Duration(milliseconds: v.toInt())),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos)),
                      Text(_fmt(dur)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Controls extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_previous),
          onPressed: player.skipToPrevious,
        ),
        StreamBuilder<bool>(
          stream: player.playingStream,
          builder: (context, snap) {
            final playing = snap.data ?? false;
            return IconButton(
              iconSize: 64,
              icon: Icon(
                  playing ? Icons.pause_circle : Icons.play_circle),
              onPressed: () =>
                  playing ? player.pause() : player.play(),
            );
          },
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_next),
          onPressed: player.skipToNext,
        ),
      ],
    );
  }
}
