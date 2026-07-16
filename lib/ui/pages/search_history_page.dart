import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'search_page.dart';

class SearchHistoryPage extends ConsumerStatefulWidget {
  const SearchHistoryPage({super.key});

  @override
  ConsumerState<SearchHistoryPage> createState() => _SearchHistoryPageState();
}

class _SearchHistoryPageState extends ConsumerState<SearchHistoryPage>
    with TickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _isPopping = false;

  late final AnimationController _barAnim;
  late final Animation<double> _barExpand;
  late final AnimationController _listAnim;
  late final Animation<double> _listFade;
  late final Animation<double> _listSlide;

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

    _listAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 120),
    );

    _listSlide = Tween<double>(begin: -12, end: 0).animate(
      CurvedAnimation(
        parent: _listAnim,
        curve: const Interval(0.2, 0.7, curve: Curves.easeOutCubic),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );

    _listFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _listAnim,
        curve: const Interval(0.2, 0.6, curve: Curves.easeOut),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
        _barAnim.forward();
        _listAnim.forward();
      }
    });
  }

  @override
  void dispose() {
    _barAnim.dispose();
    _listAnim.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _popWithAnimation() async {
    if (_isPopping) return;
    _isPopping = true;

    _focus.unfocus();
    _listAnim.reverse();
    await _barAnim.reverse();

    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _goToSearch(String query) {
    _focus.unfocus();
    ref.read(searchHistoryProvider.notifier).add(query);
    ref.read(searchProvider.notifier).search(query);

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SearchPage(),
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
    final colors = ref.watch(animatedPaletteProvider);
    final history = ref.watch(searchHistoryProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            // === PINNED SEARCH BAR ===
            SliverPersistentHeader(
              pinned: true,
              delegate: _SearchBarDelegate(
                barAnim: _barAnim,
                barExpand: _barExpand,
                controller: _controller,
                focusNode: _focus,
                colors: colors,
                onPop: _popWithAnimation,
                onChanged: () => setState(() {}),
                onSubmit: (q) {
                  if (q.trim().isNotEmpty) {
                    _goToSearch(q.trim());
                  }
                },
                onClear: () {
                  _controller.clear();
                  setState(() {});
                },
              ),
            ),

            // === HISTORY LIST ===
            if (history.isNotEmpty)
              SliverToBoxAdapter(
                child: AnimatedBuilder(
                  animation: _listAnim,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _listSlide.value),
                      child: Opacity(
                        opacity: _listFade.value,
                        child: child,
                      ),
                    );
                  },
                  child: _SearchHistoryList(
                    history: history,
                    colors: colors,
                    onTapQuery: (q) => _goToSearch(q),
                    onRemove: (q) =>
                        ref.read(searchHistoryProvider.notifier).remove(q),
                    onClear: () =>
                        ref.read(searchHistoryProvider.notifier).clear(),
                  ),
                ),
              )
            else
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(colors: colors),
              ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PINNED SEARCH BAR DELEGATE
// ═══════════════════════════════════════════════════════════════════════════

class _SearchBarDelegate extends SliverPersistentHeaderDelegate {
  final AnimationController barAnim;
  final Animation<double> barExpand;
  final TextEditingController controller;
  final FocusNode focusNode;
  final dynamic colors;
  final VoidCallback onPop;
  final VoidCallback onChanged;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  _SearchBarDelegate({
    required this.barAnim,
    required this.barExpand,
    required this.controller,
    required this.focusNode,
    required this.colors,
    required this.onPop,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
  });

  @override
  double get minExtent => 88;

  @override
  double get maxExtent => 88;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: colors.background,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: AnimatedBuilder(
        animation: barAnim,
        builder: (context, child) {
          final expand = barExpand.value;
          final maxWidth = MediaQuery.of(context).size.width - 32;
          const startWidth = 200.0;

          return Container(
            height: 60,
            width: startWidth + (maxWidth - startWidth) * expand,
            decoration: BoxDecoration(
              color: colors.elevated,
              borderRadius: BorderRadius.circular(16),
            ),
            child: child,
          );
        },
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_rounded,
                  size: 24, color: colors.textPrimary),
              onPressed: onPop,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
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
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: (_) => onChanged(),
                onSubmitted: onSubmit,
              ),
            ),
            if (controller.text.isNotEmpty)
              IconButton(
                icon: Icon(Icons.close_rounded,
                    size: 22, color: colors.textPrimary),
                onPressed: onClear,
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SearchBarDelegate oldDelegate) {
    return colors != oldDelegate.colors;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  SEARCH HISTORY LIST
// ═══════════════════════════════════════════════════════════════════════════

class _SearchHistoryList extends StatelessWidget {
  const _SearchHistoryList({
    required this.history,
    required this.colors,
    required this.onTapQuery,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> history;
  final dynamic colors;
  final ValueChanged<String> onTapQuery;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with "Clear all"
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent searches',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final q in history)
          _HistoryTile(
            query: q,
            colors: colors,
            onTap: () => onTapQuery(q),
            onRemove: () => onRemove(q),
          ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.query,
    required this.colors,
    required this.onTap,
    required this.onRemove,
  });

  final String query;
  final dynamic colors;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: 20,
                color: colors.textTertiary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  query,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: colors.textTertiary,
                ),
                onPressed: onRemove,
              ),
            ],
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