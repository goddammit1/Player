import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/now_playing_overlay.dart';
import 'search/search_bar_widgets.dart';
import 'search/search_track_tiles.dart';
import 'search_history_page.dart';
import 'settings_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    this.showNowPlayingOverlay = true,
    this.showInPageSearchBar = true,
  });

  /// Отключает встроенный мини-плеер поверх страницы. Нужно, когда страница
  /// встраивается в десктопный shell — там свою панель плеера рисует
  /// [DesktopPlayerBar] (см. ui/desktop/desktop_player_bar.dart).
  final bool showNowPlayingOverlay;

  /// Показывать ли строку поиска внутри страницы. Десктопный shell передаёт
  /// `false`: там единственная строка поиска — в верхней панели (см.
  /// ui/desktop/desktop_top_bar.dart), а страница показывает только
  /// результаты. Мобильная версия (Android/iOS) не меняется — по умолчанию
  /// [true], со своей строкой ввода.
  final bool showInPageSearchBar;

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
    final state = ref.read(searchProvider); // берём текущий state
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            SearchHistoryPage(initialQuery: state.query),
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
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isDesktop ? 900 : double.infinity,
              ),
              child: SafeArea(
                // Верхняя строка поиска на мобильных (showInPageSearchBar=true)
                // должна получать системный safe-area отступ, иначе уйдёт под
                // notch/статус-бар. На десктопе (без строки в странице) отступ
                // не нужен — верхнюю панель с поиском рисует shell.
                top: widget.showInPageSearchBar,
                bottom: false,
                child: CustomScrollView(
                  slivers: [
                    // === PINNED SEARCH BAR ===
                    if (widget.showInPageSearchBar)
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: SearchBarDelegate(
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
                    if (!widget.showInPageSearchBar)
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),

                    // === FILTERS (no animation) ===
                    if (state.results.isNotEmpty || state.loading)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16, top: 4),
                          child: SearchFilterChips(
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
                        child: SearchEmptyState(colors: colors),
                      )
                    else if (viewMode == SearchViewMode.grid)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 132),
                        sliver: StreamBuilder<MediaItem?>(
                          stream: player.mediaItem,
                          builder: (context, mediaSnap) {
                            final currentId = mediaSnap.data?.id;
                            return SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    childAspectRatio: 1.0,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                i,
                              ) {
                                final t = state.results[i];
                                final isPlaying =
                                    currentId != null &&
                                    currentId == t.globalId;
                                return SearchTrackTileGrid(
                                  track: t,
                                  isPlaying: isPlaying,
                                  onTap: () => _playTrack(t),
                                  colors: colors,
                                );
                              }, childCount: state.results.length),
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
                              delegate: SliverChildBuilderDelegate((
                                context,
                                i,
                              ) {
                                final t = state.results[i];
                                final isPlaying =
                                    currentId != null &&
                                    currentId == t.globalId;
                                return SearchTrackTileList(
                                  track: t,
                                  isPlaying: isPlaying,
                                  duration: t.duration != null
                                      ? _formatDuration(t.duration!)
                                      : null,
                                  onTap: () => _playTrack(t),
                                  colors: colors,
                                );
                              }, childCount: state.results.length),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.showNowPlayingOverlay && !isDesktop)
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

  /// Запускает воспроизведение трека, используя актуальный список
  /// результатов и находя индекс по [globalId]. Это защищает от
  /// неверного [startIndex], если список обновился между build и тапом
  /// (например, подгрузились обложки или добавился источник).
  void _playTrack(Track track) {
    final player = ref.read(playerServiceProvider);
    final results = ref.read(searchProvider).results;
    final startIndex = results.indexWhere((t) => t.globalId == track.globalId);
    if (startIndex == -1 || results.isEmpty) return;
    player.setQueue(List.of(results), startIndex: startIndex);
  }
}
