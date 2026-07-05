import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../sources/source_registry.dart';
import '../widgets/track_settings_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../../core/artwork_helper.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with TickerProviderStateMixin {
  
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _isPopping = false;
  
  late final AnimationController _barAnim;
  late final Animation<double> _barExpand;
  
  late final AnimationController _contentAnim;
  late final Animation<double> _chipsSlide;
  late final Animation<double> _chipsFade;
  late final Animation<double> _listSlide;
  late final Animation<double> _listFade;

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

    _contentAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 120),
    );

    _chipsSlide = Tween<double>(begin: -12, end: 0).animate(
      CurvedAnimation(
        parent: _contentAnim,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOutCubic),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );
    _chipsFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _contentAnim,
        curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );

    _listSlide = Tween<double>(begin: 16, end: 0).animate(
      CurvedAnimation(
        parent: _contentAnim,
        curve: const Interval(0.5, 0.9, curve: Curves.easeOutCubic),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );
    _listFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _contentAnim,
        curve: const Interval(0.5, 0.8, curve: Curves.easeOut),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
        _barAnim.forward();
        _contentAnim.forward();
      }
    });
  }

  @override
  void dispose() {
    _barAnim.dispose();
    _contentAnim.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _popWithAnimation() async {
    if (_isPopping) return;
    _isPopping = true;
    
    _focus.unfocus();
    _contentAnim.reverse();
    await _barAnim.reverse();
    
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final player = ref.read(playerServiceProvider);
    final searchCtl = ref.read(searchProvider.notifier);
    final sources = SourceRegistry.instance.searchable;
    final currentSourceId = state.sourceId;
    final colors = ref.watch(animatedPaletteProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // === SEARCHBAR ===
                AnimatedBuilder(
                  animation: _barAnim,
                  builder: (context, child) {
                    final expand = _barExpand.value;
                    final maxWidth = MediaQuery.of(context).size.width - 32;
                    const startWidth = 200.0;
                    
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Container(
                        height: 60,
                        width: startWidth + (maxWidth - startWidth) * expand,
                        decoration: BoxDecoration(
                          color: colors.elevated,
                          borderRadius: BorderRadius.circular(32 - 20 * expand),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back_rounded, size: 24, color: colors.textPrimary),
                        onPressed: _popWithAnimation,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          textInputAction: TextInputAction.search,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 16,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search...',
                            hintStyle: TextStyle(color: colors.textSecondary),
                            border: InputBorder.none,
                            isCollapsed: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 14),
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (q) => searchCtl.search(q),
                        ),
                      ),
                      if (state.loading)
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: colors.textPrimary),
                          ),
                        )
                      else if (_controller.text.isNotEmpty)
                        IconButton(
                          icon: Icon(Icons.close_rounded, size: 22, color: colors.textPrimary),
                          onPressed: () {
                            _controller.clear();
                            searchCtl.search('');
                            setState(() {});
                          },
                        )
                      else
                        const SizedBox(width: 12),
                    ],
                  ),
                ),

                // === FILTERS ===
                AnimatedBuilder(
                  animation: _contentAnim,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _chipsSlide.value),
                      child: Opacity(
                        opacity: _chipsFade.value,
                        child: child,
                      ),
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _FilterChips(
                        sources: sources,
                        currentSourceId: currentSourceId,
                        onSelected: searchCtl.setSourceId,
                        colors: colors,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),

                if (state.error != null)
                  Container(
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

                // === LIST ===
                Expanded(
                  child: AnimatedBuilder(
                    animation: _contentAnim,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(0, _listSlide.value),
                        child: Opacity(
                          opacity: _listFade.value,
                          child: child,
                        ),
                      );
                    },
                    child: state.results.isEmpty && !state.loading
                        ? _EmptyState(colors: colors)
                        : StreamBuilder<MediaItem?>(
                            stream: player.mediaItem,
                            builder: (context, mediaSnap) {
                              final currentId = mediaSnap.data?.id;
                              return ListView.builder(
                                itemCount: state.results.length,
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 132),
                                itemBuilder: (context, i) {
                                  final t = state.results[i];
                                  final isPlaying = currentId != null &&
                                      currentId == t.globalId;
                                  return _TrackTile(
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
                              );
                            },
                          ),
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

class _FilterChips extends StatefulWidget {
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
  State<_FilterChips> createState() => _FilterChipsState();
}

class _FilterChipsState extends State<_FilterChips>
    with TickerProviderStateMixin {
  
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _slides;
  late final List<Animation<double>> _fades;

  @override
  void initState() {
    super.initState();
    
    final entries = <String>[
      kAllSourcesId,
      for (final s in widget.sources) s.id as String,
    ];
    
    final count = entries.length;
    
    _controllers = List.generate(
      count,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 350),
      ),
    );
    
    _slides = List.generate(
      count,
      (i) => Tween<double>(begin: -16, end: 0).animate(
        CurvedAnimation(
          parent: _controllers[i],
          curve: Curves.easeOutCubic,
        ),
      ),
    );
    
    _fades = List.generate(
      count,
      (i) => Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _controllers[i],
          curve: Curves.easeOut,
        ),
      ),
    );

    for (var i = 0; i < count; i++) {
      Future.delayed(Duration(milliseconds: i * 100), () {
        if (mounted) _controllers[i].forward();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = <({String id, String label})>[
      (id: kAllSourcesId, label: 'All'),
      for (final s in widget.sources)
        (id: s.id as String, label: s.displayName as String),
    ];

    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final e = entries[i];
          final selected = e.id == widget.currentSourceId;
          
          return AnimatedBuilder(
            animation: _controllers[i],
            builder: (context, _) {
              return Transform.translate(
                offset: Offset(0, _slides[i].value),
                child: Opacity(
                  opacity: _fades[i].value,
                  child: _FilterPill(
                    icon: _iconFor(e.id),
                    label: e.label,
                    selected: selected,
                    onTap: () => widget.onSelected(e.id),
                    colors: widget.colors,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static IconData _iconFor(String id) {
    switch (id) {
      case kAllSourcesId:
        return Icons.public_rounded;
      case 'youtube':
        return Icons.play_circle_fill_rounded;
      case 'muzmo':
        return Icons.music_note_rounded;
      case 'soundcloud':
        return Icons.cloud_rounded;
      default:
        return Icons.library_music_rounded;
    }
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? colors.elevatedHi : colors.elevated,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: selected ? colors.textPrimary : colors.textTertiary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? colors.textPrimary : colors.textTertiary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    this.duration,
    required this.colors,
  });

  final dynamic track;
  final bool isPlaying;
  final VoidCallback onTap;
  final String? duration;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final accent = isPlaying ? colors.textPrimary : colors.textPrimary;

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
                          color: accent,
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
                        track.title as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist as String,
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

