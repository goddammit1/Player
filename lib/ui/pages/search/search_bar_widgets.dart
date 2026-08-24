import 'package:flutter/material.dart';

/// Вложенный виджет «поиск через реф-колбэки». UI отделён от состояния:
/// содержит только разметку и делегирует действия колбэкам, которые
/// передаёт [SearchPage].

// ═══════════════════════════════════════════════════════════════════════════
//  PINNED SEARCH BAR DELEGATE
// ═══════════════════════════════════════════════════════════════════════════

class SearchBarDelegate extends SliverPersistentHeaderDelegate {
  final AnimationController barAnim;
  final Animation<double> barExpand;
  final dynamic colors;
  final String query;
  final VoidCallback onPop;
  final VoidCallback onTapSearch;
  final VoidCallback onTapSettings;

  SearchBarDelegate({
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
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: colors.background,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          _SearchCircleButton(
            icon: Icons.arrow_back_rounded,
            onTap: onPop,
            colors: colors,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SearchPill(
              colors: colors,
              query: query,
              onTap: onTapSearch,
            ),
          ),
          const SizedBox(width: 10),
          _SearchCircleButton(
            icon: Icons.settings_rounded,
            onTap: onTapSettings,
            colors: colors,
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant SearchBarDelegate oldDelegate) {
    return colors != oldDelegate.colors || query != oldDelegate.query;
  }
}

class _SearchCircleButton extends StatelessWidget {
  const _SearchCircleButton({
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

class SearchPill extends StatelessWidget {
  const SearchPill({
    super.key,
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
                      color: query.isEmpty
                          ? colors.textSecondary
                          : colors.textPrimary,
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

// ═══════════════════════════════════════════════════════════════════════════
//  EMPTY STATE
// ═══════════════════════════════════════════════════════════════════════════

class SearchEmptyState extends StatelessWidget {
  const SearchEmptyState({
    super.key,
    required this.colors,
  });

  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, color: colors.textTertiary, size: 48),
          const SizedBox(height: 12),
          Text(
            'Start typing to search',
            style: TextStyle(color: colors.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  FILTER CHIPS (no animation)
// ═══════════════════════════════════════════════════════════════════════════

class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({
    super.key,
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
          _SearchFilterIconButton(
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

class _SearchFilterIconButton extends StatelessWidget {
  const _SearchFilterIconButton({
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
            border: Border.all(color: borderColor, width: 1),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }
}