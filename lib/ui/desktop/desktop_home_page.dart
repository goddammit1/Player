// lib/ui/desktop/desktop_home_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../widgets/artwork.dart';
import '../widgets/playlist_reorder_scope.dart';
import '../widgets/reorderable_playlist_card.dart';
import 'design/dimens.dart';

class DesktopHomePage extends ConsumerWidget {
  const DesktopHomePage({super.key, required this.onOpenPlaylist});

  final void Function(String playlistId) onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final colors = ref.watch(animatedPaletteProvider);

    return async.when(
      data: (playlists) => _buildBody(context, ref, playlists, colors),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Text(
          'Could not load playlists: $err',
          style: TextStyle(color: colors.textSecondary),
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
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 16),
          child: Text(
            'Playlists',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 64,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final columns = (c.maxWidth / 200).floor().clamp(2, 7);
              return PlaylistReorderScope(
                crossAxisCount: columns,
                mainAxisSpacing: 24,
                crossAxisSpacing: 24,
                itemExtent: playlists.length,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(36, 8, 36, 36),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 24,
                    crossAxisSpacing: 24,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: playlists.length + 1,
                  itemBuilder: (context, i) {
                    if (i == playlists.length) {
                      return _NewPlaylistCard(
                        colors: colors,
                        onTap: () => _showCreateDialog(context, ref, colors),
                      );
                    }
                    final p = playlists[i];
                    return ReorderablePlaylistCard(
                      key: ValueKey('reorder_${p.id}'),
                      index: i,
                      onReorder: ref
                          .read(playlistRepositoryProvider)
                          .reorderPlaylists,
                      child: _PlaylistCard(
                        playlist: p,
                        colors: colors,
                        onOpen: () => onOpenPlaylist(p.id),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showCreateDialog(
    BuildContext context,
    WidgetRef ref,
    AppColors colors,
  ) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dimens.radiusCard),
        ),
        title: Text(
          'New playlist',
          style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: colors.textPrimary),
          cursorColor: colors.elevatedHi,
          decoration: InputDecoration(
            hintText: 'Name',
            hintStyle: TextStyle(color: colors.textTertiary),
            filled: true,
            fillColor: colors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.outline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.elevatedHi, width: 2),
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.elevatedHi,
              foregroundColor: colors.textPrimary,
            ),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final p = ref.read(playlistRepositoryProvider).create(name);
    if (!context.mounted) return;
    onOpenPlaylist(p.id);
  }
}

/// Карточка плейлиста с hover-анимацией, бейджем треков и контекстным меню
class _PlaylistCard extends StatefulWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.colors,
    required this.onOpen,
  });

  final Playlist playlist;
  final AppColors colors;
  final VoidCallback onOpen;

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _isHovered = false;

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      color: widget.colors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(Icons.edit_rounded, size: 18, color: widget.colors.textPrimary),
              const SizedBox(width: 10),
              Text('Rename', style: TextStyle(color: widget.colors.textPrimary)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: const Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
              SizedBox(width: 10),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    ).then((v) {
      if (!mounted || v == null) return;
      if (v == 'rename') {
        _showRenameDialog(context, widget.playlist, widget.colors);
      } else if (v == 'delete') {
        _confirmDelete(context, widget.playlist, widget.colors);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        child: Column(
          children: [
            Expanded(
              child: AnimatedScale(
                scale: _isHovered ? 1.03 : 1.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Dimens.radiusCard),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _MosaicCover(
                          playlist: widget.playlist,
                          colors: widget.colors,
                        ),

                        // Кнопка меню действий (плавно появляется при hover)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 140),
                            opacity: _isHovered ? 1.0 : 0.0,
                            child: GestureDetector(
                              onTapDown: (d) => _showContextMenu(
                                  context, d.globalPosition),
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withValues(alpha: 0.6),
                                ),
                                child: Icon(
                                  Icons.more_vert_rounded,
                                  size: 18,
                                  color: widget.colors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Полупрозрачный круглый бейдж с числом треков
                        if (widget.playlist.tracks.isNotEmpty)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${widget.playlist.tracks.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.playlist.name,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _isHovered
                    ? widget.colors.textPrimary
                    : widget.colors.textPrimary.withValues(alpha: 0.9),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Мозаичная обложка 2x2 (или цельная, если трек один)
class _MosaicCover extends StatelessWidget {
  const _MosaicCover({required this.playlist, required this.colors});

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
          return Container(
            color: colors.elevatedVariant,
            child: Center(
              child: Icon(
                Icons.music_note_rounded,
                color: colors.textTertiary,
                size: 48,
              ),
            ),
          );
        }

        // Если обложка одна — выводим на весь размер без разрезания на мозаику
        if (thumbs.length == 1) {
          return Artwork(url: thumbs.first, size: side, borderRadius: 0);
        }

        final half = side / 2;
        final urls = <String?>[...thumbs];
        while (urls.length < 4) {
          urls.add(null);
        }
        return Column(
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
        );
      },
    );
  }
}

/// Карточка «new playlist» с анимацией hover/press и динамической темой
class _NewPlaylistCard extends StatefulWidget {
  const _NewPlaylistCard({
    required this.colors,
    required this.onTap,
  });

  final AppColors colors;
  final VoidCallback onTap;

  @override
  State<_NewPlaylistCard> createState() => _NewPlaylistCardState();
}

class _NewPlaylistCardState extends State<_NewPlaylistCard> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.colors.elevatedHi;
    final idleColor = widget.colors.elevatedHi.withValues(alpha: 0.35);
    final borderColor = _isHovered ? activeColor : idleColor;

    final iconScale = (_isHovered && !_isPressed) ? 1.12 : 1.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        child: Column(
          children: [
            Expanded(
              child: AnimatedScale(
                scale: _isPressed ? 0.97 : 1.0,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    color: _isHovered
                        ? widget.colors.elevatedHi.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(Dimens.radiusCard),
                    border: Border.all(
                      color: borderColor,
                      width: 3.0,
                    ),
                  ),
                  child: Center(
                    child: AnimatedScale(
                      scale: iconScale,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.add_rounded,
                        size: 56,
                        color: _isHovered
                            ? widget.colors.textPrimary
                            : widget.colors.elevatedHi,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'new playlist',
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isHovered
                    ? widget.colors.textPrimary
                    : widget.colors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Диалоги контекстного меню плейлиста
// ═══════════════════════════════════════════════════════════════════════════

Future<void> _showRenameDialog(
  BuildContext context,
  Playlist playlist,
  AppColors colors,
) async {
  final ref = ProviderScope.containerOf(context);
  final controller = TextEditingController(text: playlist.name);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );

  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dimens.radiusCard),
      ),
      title: Text(
        'Rename playlist',
        style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: colors.textPrimary),
        cursorColor: colors.elevatedHi,
        decoration: InputDecoration(
          hintText: 'Name',
          hintStyle: TextStyle(color: colors.textTertiary),
          filled: true,
          fillColor: colors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.elevatedHi, width: 2),
          ),
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.elevatedHi,
            foregroundColor: colors.textPrimary,
          ),
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty) return;
  ref.read(playlistRepositoryProvider).rename(playlist.id, name.trim());
}

Future<void> _confirmDelete(
  BuildContext context,
  Playlist playlist,
  AppColors colors,
) async {
  final ref = ProviderScope.containerOf(context);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dimens.radiusCard),
      ),
      title: Text(
        'Delete playlist',
        style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
      ),
      content: Text(
        'Delete "${playlist.name}"?',
        style: TextStyle(color: colors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  ref.read(playlistRepositoryProvider).delete(playlist.id);
}

