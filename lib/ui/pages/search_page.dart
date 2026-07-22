import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/track_settings_sheet.dart';
import '../../core/artwork_helper.dart';
import 'search_history_page.dart';
import 'settings_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with TickerProviderStateMixin {
  bool _isPopping = false;

  late final AnimationController _barAnim;
  late final Animation<double> _barExpand;

  @override
  void initState() {
    super.initState();

    _barAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 180),
    );

    _barExpand = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _barAnim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _barAnim.forward();
      }
    });
  }

  @override
  void dispose() {
    _barAnim.dispose();
    super.dispose();
  }

  Future<void> _popWithAnimation() async {
    if (_isPopping) return;
    _isPopping = true;

    await _barAnim.reverse();

    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _goToSearchHistory() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SearchHistoryPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return child;
        },
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final player = ref.read(playerServiceProvider);
    final searchCtl = ref.read(searchProvider.notifier);
    final sources = SourceRegistry.instance.searchable;
    final currentSourceId = state.sourceId;
    final colors = ref.watch(animatedPaletteProvider);
    final viewMode = ref.watch(searchViewModeProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                // === PINNED SEARCH BAR ===
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SearchBarDelegate(
                    barAnim: _barAnim,
                    barExpand: _barExpand,
                    colors: colors,
                    query: state.query,
                    onPop: _popWithAnimation,
                    onTapSearch: _goToSearchHistory,
                    onTapSettings: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsPage(),
                        ),
                      );
                    },
                  ),
                ),

                // === FILTERS (no animation) ===
                if (state.results.isNotEmpty || state.loading)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16, top: 4),
                      child: _FilterChips(
                        sources: sources,
                        currentSourceId: currentSourceId,
                        onSelected: (id) {
                          if (id == currentSourceId) {
                            searchCtl.setSourceId(kAllSourcesId);
                          } else {
                            searchCtl.setSourceId(id);
                          }
                        },
                        colors: colors,
                      ),
                    ),
                  ),

                // === ERROR ===
                if (state.error != null)
                  SliverToBoxAdapter(
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ),

                // === CONTENT: GRID OR LIST ===
                if (state.results.isEmpty && !state.loading)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(colors: colors),
                  )
                else if (viewMode == SearchViewMode.grid)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 132),
                    sliver: StreamBuilder<MediaItem?>(
                      stream: player.mediaItem,
                      builder: (context, mediaSnap) {
                        final currentId = mediaSnap.data?.id;
                        return SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.0,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final t = state.results[i];
                              final isPlaying = currentId != null && currentId == t.globalId;
                              return _TrackTileGrid(
                                track: t,
                                isPlaying: isPlaying,
                                onTap: () => player.setQueue(
                                  state.results,
                                  startIndex: i,
                                ),
                                colors: colors,
                              );
                            },
                            childCount: state.results.length,
                          ),
                        );
                      },
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 132),
                    sliver: StreamBuilder<MediaItem?>(
                      stream: player.mediaItem,
                      builder: (context, mediaSnap) {
                        final currentId = mediaSnap.data?.id;
                        return SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final t = state.results[i];
                              final isPlaying = currentId != null && currentId == t.globalId;
                              return _TrackTileList(
                                track: t,
                                isPlaying: isPlaying,
                                duration: t.duration != null
                                    ? _formatDuration(t.duration!)
                                    : null,
                                onTap: () => player.setQueue(
                                  state.results,
                                  startIndex: i,
                                ),
                                colors: colors,
                              );
                            },
                            childCount: state.results.length,
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PINNED SEARCH BAR DELEGATE
// ═══════════════════════════════════════════════════════════════════════════

class _SearchBarDelegate extends SliverPersistentHeaderDelegate {
  final AnimationController barAnim;
  final Animation<double> barExpand;
  final dynamic colors;
  final String query;
  final VoidCallback onPop;
  final VoidCallback onTapSearch;
  final VoidCallback onTapSettings;

  _SearchBarDelegate({
    required this.barAnim,
    required this.barExpand,
    required this.colors,
    required this.query,
    required this.onPop,
    required this.onTapSearch,
    required this.onTapSettings,
  });

  @override
  double get minExtent => 88;

  @override
  double get maxExtent => 88;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: colors.background,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          _CircleButton(
            icon: Icons.arrow_back_rounded,
            onTap: onPop,
            colors: colors,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SearchPill(
              colors: colors,
              query: query,
              onTap: onTapSearch,
            ),
          ),
          const SizedBox(width: 10),
          _CircleButton(
            icon: Icons.settings_rounded,
            onTap: onTapSettings,
            colors: colors,
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SearchBarDelegate oldDelegate) {
    return colors != oldDelegate.colors || query != oldDelegate.query;
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: colors.textPrimary, size: 20),
        ),
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({
    required this.colors,
    required this.query,
    required this.onTap,
  });

  final dynamic colors;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    query.isEmpty ? 'Search...' : query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: query.isEmpty ? colors.textSecondary : colors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_rounded,
            color: colors.textTertiary,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            'Start typing to search',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  FILTER CHIPS (no animation)
// ═══════════════════════════════════════════════════════════════════════════

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.sources,
    required this.currentSourceId,
    required this.onSelected,
    required this.colors,
  });

  final List<dynamic> sources;
  final String currentSourceId;
  final ValueChanged<String> onSelected;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final entries = sources;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          _FilterIconButton(
            icon: _iconFor(entries[i].id as String),
            selected: entries[i].id == currentSourceId,
            onTap: () => onSelected(entries[i].id as String),
            colors: colors,
          ),
        ],
      ],
    );
  }

  static IconData _iconFor(String id) {
    switch (id) {
      case 'muzmo':
        return Icons.music_note_rounded;
      case 'soundcloud':
        return Icons.cloud_rounded;
      default:
        return Icons.library_music_rounded;
    }
  }
}

class _FilterIconButton extends StatelessWidget {
  const _FilterIconButton({
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final bgColor = selected ? colors.textPrimary : Colors.transparent;
    final iconColor = selected ? colors.background : colors.textPrimary;
    final borderColor = colors.textPrimary;

    return Material(
      color: bgColor,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  GRID TRACK TILE
// ═══════════════════════════════════════════════════════════════════════════

class _TrackTileGrid extends StatefulWidget {
  const _TrackTileGrid({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    required this.colors,
  });

  final Track track;
  final bool isPlaying;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  State<_TrackTileGrid> createState() => _TrackTileGridState();
}

class _TrackTileGridState extends State<_TrackTileGrid> {
  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final colors = widget.colors;
    final duration = track.duration != null ? _formatDuration(track.duration!) : null;

    // Ограничиваем размер декода: Genius нередко отдаёт оригинал
    // 2000x2000+ (несколько МБ), а тут 20 плиток × 2 слоя. Полноразмерный
    // декод давил на память — обложки вылетали из кэша и «мигали».
    // Задаём только ширину, чтобы сохранить пропорции (16:9 у YouTube).
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cellPx =
        (((MediaQuery.of(context).size.width - 40) / 2) * dpr).round();

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: () => showTrackSettingsSheet(context, track: track),
      child: SizedBox(
        width: 160,
        height: 160,
        child: Stack(
          children: [
            ClipSmoothRect(
              radius: SmoothBorderRadius(
                cornerRadius: 40,
                cornerSmoothing: 1.0,
              ),
              child: SizedBox(
                width: 160,
                height: 160,
                child: track.artworkUrl != null && track.artworkUrl!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: track.artworkUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: cellPx,
                        placeholder: (context, url) => Container(
                          color: colors.elevated,
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: colors.elevated,
                          child: Icon(
                            Icons.music_note_rounded,
                            color: colors.textTertiary,
                            size: 32,
                          ),
                        ),
                      )
                    : Container(
                        color: colors.elevated,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: colors.textTertiary,
                          size: 32,
                        ),
                      ),
              ),
            ),

            if (track.artworkUrl != null && track.artworkUrl!.isNotEmpty)
              ClipSmoothRect(
                radius: SmoothBorderRadius(
                  cornerRadius: 40,
                  cornerSmoothing: 1.0,
                ),
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0xFF000000),
                      ],
                      stops: [0.0, 0.4, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: SizedBox(
                      width: 160,
                      height: 160,
                      child: CachedNetworkImage(
                        imageUrl: track.artworkUrl!,
                        fit: BoxFit.cover,
                        // Слой всё равно блюрится sigma=12 —
                        // четверти разрешения достаточно.
                        memCacheWidth: cellPx ~/ 4,
                      ),
                    ),
                  ),
                ),
              ),

            ClipSmoothRect(
              radius: SmoothBorderRadius(
                cornerRadius: 40,
                cornerSmoothing: 1.0,
              ),
              child: Container(
                width: 160,
                height: 160,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00161616),
                      Color(0x00161616),
                      Color(0x80161616),
                      Color(0xCC161616),
                    ],
                    stops: [0.0, 0.35, 0.65, 1.0],
                  ),
                ),
              ),
            ),

            if (widget.isPlaying)
              ClipSmoothRect(
                radius: SmoothBorderRadius(
                  cornerRadius: 40,
                  cornerSmoothing: 1.0,
                ),
                child: Container(
                  width: 160,
                  height: 160,
                  color: Colors.black.withValues(alpha: 0.3),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.equalizer_rounded,
                    color: colors.textPrimary,
                    size: 28,
                  ),
                ),
              ),

            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    showAddToPlaylistSheet(context, track);
                  },
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.textPrimary.withValues(alpha: 0.9),
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 16,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              left: 16,
              bottom: 24,
              right: duration != null ? 48 : 16,
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),

            Positioned(
              left: 16,
              bottom: 12,
              right: duration != null ? 48 : 16,
              child: Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ),

            if (duration != null)
              Positioned(
                right: 16,
                bottom: 18,
                child: Text(
                  duration,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  LIST TRACK TILE
// ═══════════════════════════════════════════════════════════════════════════

class _TrackTileList extends StatelessWidget {
  const _TrackTileList({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    this.duration,
    required this.colors,
  });

  final Track track;
  final bool isPlaying;
  final VoidCallback onTap;
  final String? duration;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isPlaying ? colors.elevatedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => showTrackSettingsSheet(
            context,
            track: track,
          ),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Artwork(
                      url: track.artworkUrl,
                      size: 54,
                      aspectRatio: artAspectRatio(track),
                      borderRadius: 10,
                    ),
                    if (isPlaying)
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.equalizer_rounded,
                          color: colors.textPrimary,
                          size: 22,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                if (duration != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    duration!,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}