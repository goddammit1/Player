import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../../models/playlist.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../../core/artwork_helper.dart';


/// Экран отдельного плейлиста: большая обложка-мозаика, имя, кнопка
/// Play, список треков. Используется и для пустого («только что
/// создан»), и для заполненного состояний.
class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final list = async.value ?? const <Playlist>[];
    Playlist? playlist;
    for (final p in list) {
      if (p.id == playlistId) {
        playlist = p;
        break;
      }
    }

    if (playlist == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'Playlist deleted',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }

    final p = playlist;
    final player = ref.read(playerServiceProvider);
    final repo = ref.read(playlistRepositoryProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: AppColors.background,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.chevron_left_rounded, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () =>
                          _showPlaylistMenu(context, ref, repo, p),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: LayoutBuilder(
                            builder: (_, c) => ArtworkMosaic(
                              urls: p.coverThumbnails,
                              size: c.maxWidth,
                              borderRadius: 24,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          p.name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${p.tracks.length} tracks',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 52,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.textPrimary,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                              ),
                              minimumSize: const Size(160, 52),
                              elevation: 0,
                            ),
                            onPressed: p.tracks.isEmpty
                                ? null
                                : () => player.setQueue(p.tracks),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (p.tracks.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          'No tracks yet.\nFind some via Search 🔍',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 120),
                    sliver: SliverList.builder(
                      itemCount: p.tracks.length,
                      itemBuilder: (context, i) {
                        final t = p.tracks[i];
                        return Dismissible(
                          key: ValueKey(t.globalId),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            color: Colors.red.withValues(alpha: 0.2),
                            child: const Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.redAccent,
                            ),
                          ),
                          onDismissed: (_) =>
                              repo.removeTrack(p.id, t.globalId),
                          child: ListTile(
                            leading: Artwork(
                              url: t.artworkUrl,
                              size: 48,
                              borderRadius: 8,
                              aspectRatio: artAspectRatio(t),  // ← добавьте
                            ),
                            title: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              t.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            trailing: t.duration != null
                                ? Text(
                                    _fmt(t.duration!),
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                    ),
                                  )
                                : null,
                            onTap: () =>
                                player.setQueue(p.tracks, startIndex: i),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          const NowPlayingOverlay(),

        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _showPlaylistMenu(
    BuildContext context,
    WidgetRef ref,
    repo,
    Playlist p,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Rename'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await _askRename(context, ref, p);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Delete playlist',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  ref.read(playlistRepositoryProvider).delete(p.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _askRename(
    BuildContext context,
    WidgetRef ref,
    Playlist p,
  ) async {
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Rename playlist',
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Name',
              hintStyle: TextStyle(color: AppColors.textTertiary),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (name != null && name.isNotEmpty) {
      ref.read(playlistRepositoryProvider).rename(p.id, name);
    }
  }
}
