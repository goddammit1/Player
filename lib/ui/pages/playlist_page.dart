import 'dart:math' as math;

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

/// Провайдер текущего globalId трека из плеера.
/// Сравниваем с track.globalId чтобы показать оверлей «сейчас играет».
final _currentTrackIdProvider = StreamProvider<String?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem.map((item) => item?.id);
});

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
            leading: _CircleButton(
              icon: Icons.chevron_left_rounded,
              onPressed: () => Navigator.of(context).pop(),
              colors: colors,
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

    final playableTracks = p.tracks
        .where((t) => !SourceRegistry.instance.isDisabled(t.sourceId))
        .toList();

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
                  // ── Static TopBar — unified approach, full control ──
                  SliverAppBar(
                    pinned: true,
                    floating: false,
                    snap: false,
                    backgroundColor: colors.background,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    toolbarHeight: 88,
                    automaticallyImplyLeading: false,
                    title: Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 12),
                      child: Row(
                        children: [
                          _CircleButton(
                            icon: Icons.chevron_left_rounded,
                            onPressed: () => Navigator.of(context).pop(),
                            colors: colors,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _CircleButton(
                            icon: Icons.more_horiz_rounded,
                            onPressed: () => _showPlaylistMenu(context, ref, repo, p),
                            colors: colors,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Artwork with track count badge ──
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: LayoutBuilder(
                          builder: (_, c) => Stack(
                            children: [
                              ArtworkMosaic(
                                urls: p.coverThumbnails,
                                size: c.maxWidth,
                                borderRadius: 24,
                              ),
                              // Track count badge — bottom right
                              if (p.tracks.isNotEmpty)
                                Positioned(
                                  right: 12,
                                  bottom: 12,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      '${p.tracks.length}',
                                      style: TextStyle(
                                        color: colors.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
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

                  // ── Play / Shuffle buttons ──
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Row(
                        children: [
                          // Play/Pause button
                          Expanded(
                            child: _PlayPauseButton(
                              playableTracks: playableTracks,
                              colors: colors,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Shuffle button
                          Expanded(
                            child: SizedBox(
                              height: 60,
                              child: ElevatedButton.icon(
                                icon: Icon(
                                  Icons.shuffle_rounded,
                                  color: colors.textPrimary,
                                  size: 22,
                                ),
                                label: Text(
                                  'Shuffle',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                    letterSpacing: 0.2,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: colors.elevated,
                                  foregroundColor: colors.textPrimary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                  elevation: 0,
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: playableTracks.isEmpty
                                    ? null
                                    : () {
                                        final shuffled = [...playableTracks];
                                        shuffled.shuffle(math.Random());
                                        player.setQueue(shuffled);
                                      },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Track list or empty state ──
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
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
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
                              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                              leading: _TrackArtworkWithOverlay(
                                track: t,
                                isDisabled: isDisabled,
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
                                      final idx = playableTracks.indexWhere(
                                          (pt) => pt.globalId == t.globalId);
                                      player.setQueue(
                                        playableTracks,
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

// ═══════════════════════════════════════════════════════════════════
//  CIRCLE BUTTON (60x60, 100% rounded)
// ═══════════════════════════════════════════════════════════════════

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onPressed,
    required this.colors,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 60,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.elevated,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 28,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
///  SHARED ANIMATOR (как в HomePage)
/// ═══════════════════════════════════════════════════════════════════

/// ═══════════════════════════════════════════════════════════════════
///  TRACK ARTWORK WITH NOW-PLAYING OVERLAY
/// ═══════════════════════════════════════════════════════════════════

class _TrackArtworkWithOverlay extends ConsumerWidget {
  const _TrackArtworkWithOverlay({
    required this.track,
    required this.isDisabled,
  });

  final Track track;
  final bool isDisabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final currentIdAsync = ref.watch(_currentTrackIdProvider);
    final currentId = currentIdAsync.value;
    final isPlaying = currentId == track.globalId;

    return Stack(
      children: [
        Opacity(
          opacity: isDisabled ? 0.4 : 1.0,
          child: Artwork(
            url: track.artworkUrl,
            size: 48,
            borderRadius: 8,
            aspectRatio: artAspectRatio(track),
          ),
        ),
        // Now playing animated wave overlay
        if (isPlaying)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: _WaveBars(color: colors.elevatedHi),
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
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
///  ANIMATED WAVE BARS — looping equalizer
/// ═══════════════════════════════════════════════════════════════════

class _WaveBars extends StatefulWidget {
  const _WaveBars({required this.color});
  final Color color;

  @override
  State<_WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<_WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _barCount = 5;
  static const _barWidth = 3.0;
  static const _barGap = 2.0;
  static const _maxHeight = 20.0;
  static const _minHeight = 4.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_barCount, (i) {
            // Each bar has its own phase offset for organic wave effect
            final phase = (i / _barCount) * 2 * math.pi;
            // Double sine wave for more complex motion
            final wave = math.sin(t * 2 * math.pi + phase) * 0.5 +
                         math.sin(t * 4 * math.pi + phase * 1.5) * 0.3;
            final height = _minHeight +
                (_maxHeight - _minHeight) *
                ((wave + 0.8) / 1.6).clamp(0.0, 1.0);

            return Container(
              width: _barWidth,
              height: height,
              margin: EdgeInsets.only(
                right: i < _barCount - 1 ? _barGap : 0,
              ),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(_barWidth / 2),
              ),
            );
          }),
        );
      },
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
///  PLAY / PAUSE BUTTON — fast, reactive via Riverpod streams
/// ═══════════════════════════════════════════════════════════════════

class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton({
    required this.playableTracks,
    required this.colors,
  });

  final List<Track> playableTracks;
  final AppColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final isPlaying = ref.watch(_isPlayingProvider).value ?? false;
    final currentId = ref.watch(_currentTrackIdProvider).value;

    final isThisPlaylist = currentId != null &&
        playableTracks.any((t) => t.globalId == currentId);
    final showPause = isPlaying && isThisPlaylist;

    return SizedBox(
      height: 60,
      child: ElevatedButton.icon(
        icon: Icon(
          showPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: colors.textPrimary,
          size: 26,
        ),
        label: Text(
          showPause ? 'Pause' : 'Play',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 16,
            letterSpacing: 0.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.elevatedHi,
          foregroundColor: colors.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          elevation: 0,
          padding: EdgeInsets.zero,
        ),
        onPressed: playableTracks.isEmpty
            ? null
            : () {
                if (showPause) {
                  player.pause();
                } else {
                  player.setQueue(playableTracks);
                }
              },
      ),
    );
  }
}

/// StreamProvider для isPlaying — мгновенные обновления
final _isPlayingProvider = StreamProvider<bool>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.playingStream;
});

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