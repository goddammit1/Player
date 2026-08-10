// lib/ui/desktop/desktop_home_page.dart
//
// Десктопная главная страница: адаптивная сетка плейлистов в контентной
// области DesktopShell. Логика та же, что у мобильной HomePage
// (playlistsProvider), но вёрстка своя: больше колонок, карточки с
// мозаичными обложками, контекстное меню на карточке.
//
// Открытие плейлиста делегируется shell'у через [onOpenPlaylist] — так
// контент подменяется внутри окна, а не поверх всей раскладки.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../widgets/artwork.dart';

/// Главный раздел десктопного shell.
class DesktopHomePage extends ConsumerWidget {
  const DesktopHomePage({super.key, required this.onOpenPlaylist});

  /// Вызывается при тапе по плейлисту. Shell открывает его в контентной
  /// области (без наслоения полноэкранных маршрутов).
  final void Function(String playlistId) onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final colors = ref.watch(animatedPaletteProvider);

    return async.when(
      data: (playlists) => _buildBody(context, ref, playlists, colors),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  color: colors.textSecondary, size: 40),
              const SizedBox(height: 12),
              Text(
                'Could not load playlists',
                style: TextStyle(color: colors.textPrimary, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                err.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    List<Playlist> playlists,
    AppColors colors,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Text(
                'Playlists',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _showCreateDialog(context, ref),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New playlist'),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.elevatedHi,
                  foregroundColor: Colors.black,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final columns = (c.maxWidth / 240).floor().clamp(2, 8);
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
                  childAspectRatio: 0.78,
                ),
                itemCount: playlists.length + 1,
                itemBuilder: (context, i) {
                  if (i == playlists.length) {
                    return _AddNewCard(
                      onTap: () => _showCreateDialog(context, ref),
                      colors: colors,
                    );
                  }
                  final p = playlists[i];
                  return _PlaylistCard(
                    playlist: p,
                    colors: colors,
                    onOpen: () => onOpenPlaylist(p.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final colors = ref.read(currentPaletteProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevated,
        title: Text('New playlist',
            style: TextStyle(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Name',
            hintStyle: TextStyle(color: colors.textTertiary),
            filled: true,
            fillColor: colors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.outline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.outline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.textPrimary),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final p = ref.read(playlistRepositoryProvider).create(name);
    if (!context.mounted) return;
    onOpenPlaylist(p.id);
  }
}

/// Карточка плейлиста: обложка (кастомная или мозаика 2×2 из обложек
/// первых треков), имя, число треков и контекстное меню.
class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.colors,
    required this.onOpen,
  });

  final Playlist playlist;
  final AppColors colors;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpen,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _PlaylistCover(playlist: playlist, colors: colors),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: PopupMenuButton<String>(
                      tooltip: 'Playlist actions',
                      color: colors.elevatedVariant,
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: colors.textPrimary.withValues(alpha: 0.9),
                        size: 20,
                      ),
                      onSelected: (v) {
                        if (v == 'rename') {
                          _showRenameDialog(context, playlist);
                        } else if (v == 'delete') {
                          _confirmDelete(context, playlist);
                        }
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(Icons.edit_rounded,
                                  size: 18, color: colors.textPrimary),
                              const SizedBox(width: 10),
                              Text('Rename',
                                  style:
                                      TextStyle(color: colors.textPrimary)),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              const Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Colors.redAccent),
                              const SizedBox(width: 10),
                              const Text('Delete',
                                  style: TextStyle(color: Colors.redAccent)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '${playlist.tracks.length} tracks',
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}


/// Обложка плейлиста: кастомное изображение, либо мозаика 2×2 из обложек
/// первых четырёх треков, либо заглушка.
class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.playlist, required this.colors});

  final Playlist playlist;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final custom = playlist.coverCustomUrl;
    final thumbs = playlist.coverThumbnails;

    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth;
        if (custom != null && custom.isNotEmpty) {
          return Artwork(url: custom, size: side, borderRadius: 0);
        }
        if (thumbs.isEmpty) {
          return ColoredBox(
            color: colors.elevatedVariant,
            child: Center(
              child: Icon(
                Icons.music_note_rounded,
                color: colors.textTertiary,
                size: side * 0.3,
              ),
            ),
          );
        }

        final half = side / 2;
        final urls = <String?>[...thumbs];
        while (urls.length < 4) {
          urls.add(null);
        }
        return ClipRect(
          child: Column(
            children: [
              Row(
                children: [
                  Artwork(url: urls[0], size: half, borderRadius: 0),
                  Artwork(url: urls[1], size: half, borderRadius: 0),
                ],
              ),
              Row(
                children: [
                  Artwork(url: urls[2], size: half, borderRadius: 0),
                  Artwork(url: urls[3], size: half, borderRadius: 0),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Карточка-кнопка «создать новый плейлист» в конце сетки.
class _AddNewCard extends StatelessWidget {
  const _AddNewCard({required this.onTap, required this.colors});

  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevatedVariant.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 40, color: colors.textSecondary),
            const SizedBox(height: 8),
            Text(
              'New playlist',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
//  Диалоги контекстного меню карточки
// ═══════════════════════════════════════════════════════════════════════════

Future<void> _showRenameDialog(BuildContext context, Playlist playlist) async {
  final ref = ProviderScope.containerOf(context);
  final colors = ref.read(currentPaletteProvider);
  final controller = TextEditingController(text: playlist.name);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );

  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.elevated,
      title: Text('Rename playlist',
          style: TextStyle(color: colors.textPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: colors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Name',
          hintStyle: TextStyle(color: colors.textTertiary),
          filled: true,
          fillColor: colors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.outline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.textPrimary),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty) return;
  ref.read(playlistRepositoryProvider).rename(playlist.id, name.trim());
}

Future<void> _confirmDelete(BuildContext context, Playlist playlist) async {
  final ref = ProviderScope.containerOf(context);
  final colors = ref.read(currentPaletteProvider);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.elevated,
      title: Text('Delete playlist',
          style: TextStyle(color: colors.textPrimary)),
      content: Text(
        'Delete "${playlist.name}"?',
        style: TextStyle(color: colors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (ok != true) return;
  ref.read(playlistRepositoryProvider).delete(playlist.id);
}

