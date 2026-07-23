import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'artwork.dart';
import '../../core/haptic_helper.dart';


Future<void> showAddToPlaylistSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    useRootNavigator: true,
    builder: (sheetCtx) => _AddToPlaylistSheet(track: track),
  );
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  const _AddToPlaylistSheet({required this.track});
  final Track track;

  @override
  ConsumerState<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  final Set<String> _selectedIds = {};
  String _searchQuery = '';
  bool _searchFocused = false;

  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      if (mounted) {
        setState(() => _searchFocused = _searchFocusNode.hasFocus);
        
        // ← Раскрываем плашку при фокусе
        if (_searchFocusNode.hasFocus) {
          _sheetController.animateTo(
            0.95,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(playlistsProvider);
    final colors = ref.watch(animatedPaletteProvider);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.51,
      minChildSize: 0.25,
      maxChildSize: 0.95,
      expand: false,
      snap: true,
      snapSizes: const [0.51, 0.95],
      controller: _sheetController,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              GestureDetector(
                onTap: () {},
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.textPrimary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // Search pill
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.elevated,
                    borderRadius: BorderRadius.circular(_searchFocused ? 5 : 20),
                  ),
                  child: TapRegion(
                    onTapOutside: (_) {
                      if (_searchFocusNode.hasFocus) {
                        _searchFocusNode.unfocus();
                      }
                    },
                    child: TextField(
                      focusNode: _searchFocusNode,
                      textAlignVertical: TextAlignVertical.center,
                      style: TextStyle(color: colors.textPrimary, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Find playlist',
                        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        isCollapsed: true,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                      onSubmitted: (_) => _searchFocusNode.unfocus(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Title
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Add to playlist',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
              // Grid
              Flexible(
                child: asyncList.when(
                  data: (list) {
                    final filtered = list.where((p) => p.name.toLowerCase().contains(_searchQuery)).toList();
                    return _PlaylistGrid(
                      playlists: filtered,
                      selectedIds: _selectedIds,
                      scrollController: scrollController,
                      onToggle: (id) {
                        HapticHelper.light(ref: ref);
                        setState(() {
                          if (_selectedIds.contains(id)) {
                            _selectedIds.remove(id);
                          } else {
                            _selectedIds.add(id);
                          }
                        });
                      },
                      track: widget.track,
                      onNewPlaylistCreated: (id) {
                        setState(() => _selectedIds.add(id));
                      },
                    );
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Failed to load',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                ),
              ),
              // Done button
              if (_selectedIds.isNotEmpty)
                Container(
                  color: Colors.transparent,
                  margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: _BottomDoneBar(
                    selectedCount: _selectedIds.length,
                    onDone: () => _onDone(context),
                    colors: colors,
                  ),
                ),
              // Transparent bottom safe area
              Container(
                height: bottomInset,
                color: Colors.transparent,
              ),
            ],
          ),
        );
      },
    );
  }

  void _onDone(BuildContext context) {
    HapticHelper.medium(ref: ref);
    final repo = ref.read(playlistRepositoryProvider);
    final colors = ref.read(currentPaletteProvider);

    for (final id in _selectedIds) {
      repo.addTrack(id, widget.track);
    }

    Navigator.of(context).pop();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _selectedIds.length == 1
              ? 'Added to playlist'
              : 'Added to ${_selectedIds.length} playlists',
          style: TextStyle(color: colors.textPrimary),
        ),
        backgroundColor: colors.elevated,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  PLAYLIST GRID (3 columns)
// ═══════════════════════════════════════════════════════════════════

class _PlaylistGrid extends StatelessWidget {
  const _PlaylistGrid({
    required this.playlists,
    required this.selectedIds,
    required this.scrollController,
    required this.onToggle,
    required this.track,
    required this.onNewPlaylistCreated,
  });

  final List<Playlist> playlists;
  final Set<String> selectedIds;
  final ScrollController scrollController;
  final ValueChanged<String> onToggle;
  final Track track;
  final ValueChanged<String> onNewPlaylistCreated;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    const crossAxisCount = 3;
    const spacing = 12.0;
    const padding = 16.0;
    final itemSize = (screenWidth - padding * 2 - spacing * (crossAxisCount - 1)) / crossAxisCount;

    if (playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No playlists yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            fontSize: 14,
          ),
        ),
      );
    }

    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(padding, 0, padding, 120),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 0.85,
      ),
      itemCount: playlists.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _NewPlaylistTile(
            onCreated: onNewPlaylistCreated,
          );
        }
        final playlist = playlists[index - 1];
        final isSelected = selectedIds.contains(playlist.id);
        return _PlaylistTile(
          playlist: playlist,
          size: itemSize,
          isSelected: isSelected,
          onTap: () => onToggle(playlist.id),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  NEW PLAYLIST TILE
// ═══════════════════════════════════════════════════════════════════

class _NewPlaylistTile extends ConsumerStatefulWidget {
  const _NewPlaylistTile({
    required this.onCreated,
  });

  final ValueChanged<String> onCreated;

  @override
  ConsumerState<_NewPlaylistTile> createState() => _NewPlaylistTileState();
}

class _NewPlaylistTileState extends ConsumerState<_NewPlaylistTile> {
  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return GestureDetector(
      onTap: () => _createNewPlaylist(context, ref),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: colors.elevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.background,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    color: colors.textPrimary,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'New playlist',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createNewPlaylist(BuildContext context, WidgetRef ref) async {
    HapticHelper.light(ref: ref);
    final colors = ref.read(currentPaletteProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            'Playlist name',
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'My playlist',
              hintStyle: TextStyle(color: colors.textTertiary),
              border: InputBorder.none,
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
        );
      },
    );

    if (name != null && name.isNotEmpty) {
      final repo = ref.read(playlistRepositoryProvider);
      final p = repo.create(name);
      widget.onCreated(p.id);

      if (context.mounted) {
        HapticHelper.medium(ref: ref);
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  PLAYLIST TILE (selection: black circle only, no blur)
// ═══════════════════════════════════════════════════════════════════

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.size,
    required this.isSelected,
    required this.onTap,
  });

  final Playlist playlist;
  final double size;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  playlist.coverThumbnails.isNotEmpty
                      ? ArtworkMosaic(
                          urls: playlist.coverThumbnails,
                          size: size,
                          borderRadius: 0,
                        )
                      : Container(
                          color: colors.elevated,
                          child: Center(
                            child: Icon(
                              Icons.music_note_rounded,
                              color: colors.textTertiary,
                              size: size * 0.3,
                            ),
                          ),
                        ),
                  if (isSelected)
                    Container(
                      color: Colors.black.withValues(alpha: 0.35),
                      child: Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  BOTTOM DONE BAR — pure pill inside transparent container
// ═══════════════════════════════════════════════════════════════════

class _BottomDoneBar extends StatelessWidget {
  const _BottomDoneBar({
    required this.selectedCount,
    required this.onDone,
    required this.colors,
  });

  final int selectedCount;
  final VoidCallback onDone;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, value * 80),
          child: child,
        );
      },
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          onPressed: onDone,
          icon: Icon(Icons.check_rounded, color: colors.textPrimary, size: 20),
          label: Text(
            'Done',
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.elevatedHi,
            foregroundColor: Colors.black,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
            padding: EdgeInsets.zero,
            minimumSize: const Size(double.infinity, 52),
          ),
        ),
      ),
    );
  }
}