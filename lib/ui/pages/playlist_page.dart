import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_backup.dart';
import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../../core/artwork_helper.dart';

/// Экран отдельного плейлиста: большая обложка-мозаика, имя, кнопка
/// Play, список треков. Используется и для пустого, и для заполненного.
class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final list = async.value ?? const <Playlist>[];
    final colors = ref.watch(animatedPaletteProvider);

    Playlist? playlist;
    for (final p in list) {
      if (p.id == playlistId) {
        playlist = p;
        break;
      }
    }

    if (playlist == null) {
      return _PageAnimator(
        child: Scaffold(
          backgroundColor: colors.background,
          appBar: AppBar(
            backgroundColor: colors.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.chevron_left_rounded, size: 28, color: colors.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: Center(
            child: Text(
              'Playlist deleted',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ),
      );
    }

    final p = playlist;
    final player = ref.read(playerServiceProvider);
    final repo = ref.read(playlistRepositoryProvider);

    return _PageAnimator(
      child: Scaffold(
        backgroundColor: colors.background,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: colors.background,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    leading: IconButton(
                      icon: Icon(Icons.chevron_left_rounded, size: 28, color: colors.textPrimary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    actions: [
                      IconButton(
                        icon: Icon(Icons.more_horiz_rounded, color: colors.textPrimary),
                        onPressed: () => _showPlaylistMenu(context, ref, repo, p),
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
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${p.tracks.length} tracks',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            height: 52,
                            child: ElevatedButton.icon(
                              icon: Icon(Icons.play_arrow_rounded, color: Colors.black),
                              label: const Text(
                                'Play',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: colors.textPrimary,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(26),
                                ),
                                minimumSize: const Size(160, 52),
                                elevation: 0,
                              ),
                              onPressed: p.tracks.isEmpty
                                  ? null
                                  : () {
                                      final playable = p.tracks
                                          .where((t) => !SourceRegistry.instance.isDisabled(t.sourceId))
                                          .toList();
                                      if (playable.isNotEmpty) {
                                        player.setQueue(playable);
                                      }
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (p.tracks.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Text(
                            'No tracks yet.\nFind some via Search 🔍',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.textSecondary,
                              height: 1.5,
                              fontSize: 14,
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
                          final isDisabled = SourceRegistry.instance.isDisabled(t.sourceId);
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
                            onDismissed: (_) => repo.removeTrack(p.id, t.globalId),
                            child: ListTile(
                              leading: Stack(
                                children: [
                                  Opacity(
                                    opacity: isDisabled ? 0.4 : 1.0,
                                    child: Artwork(
                                      url: t.artworkUrl,
                                      size: 48,
                                      borderRadius: 8,
                                      aspectRatio: artAspectRatio(t),
                                    ),
                                  ),
                                  if (isDisabled)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                          color: Colors.orange,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.warning_rounded,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDisabled
                                      ? colors.textSecondary
                                      : colors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                isDisabled
                                    ? '${t.artist} · YouTube unavailable'
                                    : t.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDisabled
                                      ? Colors.orange
                                      : colors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: isDisabled
                                  ? IconButton(
                                      icon: const Icon(
                                        Icons.find_replace_rounded,
                                        color: Colors.orange,
                                        size: 22,
                                      ),
                                      tooltip: 'Find replacement',
                                      onPressed: () => _showReplacementSheet(
                                        context, ref, p, t,
                                      ),
                                    )
                                  : (t.duration != null
                                      ? Text(
                                          _fmt(t.duration!),
                                          style: TextStyle(
                                            color: colors.textSecondary,
                                            fontSize: 12,
                                          ),
                                        )
                                      : null),
                              onTap: isDisabled
                                  ? () => _showReplacementSheet(
                                        context, ref, p, t)
                                  : () {
                                      final playable = p.tracks
                                          .where((t) => !SourceRegistry.instance.isDisabled(t.sourceId))
                                          .toList();
                                      final idx = playable.indexWhere(
                                          (pt) => pt.globalId == t.globalId);
                                      player.setQueue(
                                        playable,
                                        startIndex: idx >= 0 ? idx : 0,
                                      );
                                    },
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
    final colors = ref.read(currentPaletteProvider);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.elevated,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.edit_rounded, color: colors.textPrimary),
                title: Text('Rename', style: TextStyle(color: colors.textPrimary)),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await _askRename(context, ref, p);
                },
              ),
              ListTile(
                leading: Icon(Icons.ios_share_rounded, color: colors.textPrimary),
                title: Text('Export playlist', style: TextStyle(color: colors.textPrimary)),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await _exportPlaylist(context, p);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: Text(
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

  Future<void> _exportPlaylist(BuildContext context, Playlist p) async {
    try {
      await PlaylistBackup.exportAndShare([p]);
    } catch (e) {
      if (!context.mounted) return;
      _showInfo(context, ref: null, title: 'Export failed', body: e.toString());
    }
  }

  void _showInfo(
    BuildContext context, {
    required String title,
    required String body,
    WidgetRef? ref,
  }) {
    final colors = ref?.read(currentPaletteProvider);

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors?.elevated ?? Colors.grey[900],
          title: Text(
            title,
            style: TextStyle(color: colors?.textPrimary ?? Colors.white),
          ),
          content: Text(
            body,
            style: TextStyle(color: colors?.textSecondary ?? Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showReplacementSheet(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    Track unavailableTrack,
  ) async {
    final query = '${unavailableTrack.artist} ${unavailableTrack.title}';
    final repo = ref.read(playlistRepositoryProvider);
    final player = ref.read(playerServiceProvider);
    final colors = ref.read(currentPaletteProvider);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.elevated,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return _ReplacementSheetBody(
              query: query,
              unavailableTrack: unavailableTrack,
              scrollController: scrollController,
              onReplace: (Track replacement) {
                repo.replaceTrack(
                  playlist.id,
                  unavailableTrack.globalId,
                  replacement,
                );
                Navigator.of(sheetCtx).pop();
              },
              onPreview: (Track track) {
                player.setQueue([track]);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _askRename(
    BuildContext context,
    WidgetRef ref,
    Playlist p,
  ) async {
    final colors = ref.read(currentPaletteProvider);
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            'Rename playlist',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Name',
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

/// ═══════════════════════════════════════════════════════════════════
///  SHARED ANIMATOR (как в HomePage)
/// ═══════════════════════════════════════════════════════════════════

class _PageAnimator extends StatefulWidget {
  const _PageAnimator({required this.child});
  final Widget child;

  @override
  State<_PageAnimator> createState() => _PageAnimatorState();
}

class _PageAnimatorState extends State<_PageAnimator>
    with SingleTickerProviderStateMixin {

  late final AnimationController _anim;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<double>(begin: 10, end: 0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _fade = Tween<double>(begin: 0.7, end: 1).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _anim.forward();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _slide.value),
        child: Opacity(
          opacity: _fade.value,
          child: widget.child,
        ),
      ),
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
///  REPLACEMENT SHEET BODY (с динамическими цветами)
/// ═══════════════════════════════════════════════════════════════════

class _ReplacementSheetBody extends ConsumerStatefulWidget {
  const _ReplacementSheetBody({
    required this.query,
    required this.unavailableTrack,
    required this.scrollController,
    required this.onReplace,
    required this.onPreview,
  });

  final String query;
  final Track unavailableTrack;
  final ScrollController scrollController;
  final ValueChanged<Track> onReplace;
  final ValueChanged<Track> onPreview;

  @override
  ConsumerState<_ReplacementSheetBody> createState() => _ReplacementSheetBodyState();
}

class _ReplacementSheetBodyState extends ConsumerState<_ReplacementSheetBody> {
  List<Track> _results = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sources = SourceRegistry.instance.searchable;
      final lists = await Future.wait(
        sources.map((s) async {
          try {
            return await s.search(widget.query, limit: 10);
          } catch (_) {
            return <Track>[];
          }
        }),
      );

      final merged = <Track>[];
      var i = 0;
      var added = true;
      while (added) {
        added = false;
        for (final list in lists) {
          if (i < list.length) {
            merged.add(list[i]);
            added = true;
          }
        }
        i++;
      }

      if (mounted) {
        setState(() {
          _results = merged;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(
            'Replace "${widget.unavailableTrack.title}"',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            'Tap to preview · Long press to replace',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
        if (_loading)
          const Expanded(
            child: Center(
              child: CircularProgressIndicator(),
            ),
          )
        else if (_error != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Search failed: $_error',
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else if (_results.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No results found',
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              itemCount: _results.length,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemBuilder: (context, i) {
                final t = _results[i];
                return ListTile(
                  leading: Artwork(
                    url: t.artworkUrl,
                    size: 44,
                    borderRadius: 8,
                    aspectRatio: artAspectRatio(t),
                  ),
                  title: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    '${t.artist} · ${t.sourceId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.swap_horiz_rounded,
                      color: Colors.green,
                    ),
                    tooltip: 'Use this track',
                    onPressed: () => widget.onReplace(t),
                  ),
                  onTap: () => widget.onPreview(t),
                );
              },
            ),
          ),
      ],
    );
  }
}
