import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'artwork.dart';
import 'track_details_sheet.dart';


/// Bottom sheet выбора плейлиста для трека.
///
/// Открывается через `showModalBottomSheet`. Содержит:
/// - кнопку «New playlist» (откроет dialog для имени, создаст и сразу
///   добавит в него трек),
/// - список существующих плейлистов (название + мозаика 2×2 как
///   мини-иконка).
///
/// Возвращает `Future<void>`. После того как пользователь выбрал
/// плейлист и трек добавлен, sheet автоматически закрывается, наружу
/// показывается короткий `SnackBar` («Added to ...»).
Future<void> showAddToPlaylistSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AddToPlaylistSheet(track: track),
  );
}

class _AddToPlaylistSheet extends ConsumerWidget {
  const _AddToPlaylistSheet({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(playlistsProvider);
    final repo = ref.read(playlistRepositoryProvider);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Add to playlist',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.elevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: AppColors.textPrimary,
                ),
              ),
              title: const Text(
                'Детали трека',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () {
                Navigator.of(context).pop();
                showTrackDetailsSheet(context, track);
              },
            ),
            const Divider(color: AppColors.outline, height: 1),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.elevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  color: AppColors.textPrimary,
                ),
              ),
              title: const Text(
                'New playlist',

                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () async {
                final name = await _askName(context);
                if (name == null) return;
                final p = repo.create(name);
                repo.addTrack(p.id, track);
                if (context.mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added to “${p.name}”')),
                  );
                }
              },
            ),
            const Divider(color: AppColors.outline, height: 1),
            Flexible(
              child: asyncList.when(
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No playlists yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: list.length,
                        itemBuilder: (_, i) =>
                            _PlaylistTile(playlist: list[i], track: track),
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Failed to load',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askName(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Playlist name',
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'My playlist',
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
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist, required this.track});
  final Playlist playlist;
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: ArtworkMosaic(
        urls: playlist.coverThumbnails,
        size: 44,
        borderRadius: 10,
      ),
      title: Text(
        playlist.name,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${playlist.tracks.length} tracks',
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      onTap: () {
        ref.read(playlistRepositoryProvider).addTrack(playlist.id, track);
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added to “${playlist.name}”')),
        );
      },
    );
  }
}
