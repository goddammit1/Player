// lib/ui/desktop/desktop_shell.dart
//
// Десктопный каркас (Windows/Linux/macOS): классическая раскладка —
// боковая панель разделов слева, контентная область по центру, панель
// плеера снизу (см. DesktopPlayerBar).
//
// Корень приложения переключается в lib/main.dart по [isDesktop]:
// мобильный UI (Android/iOS) при этом не затрагивается.
//
// Разделы рендерятся в IndexedStack — состояние каждого сохраняется при
// переключении. Внутренняя навигация (например, открытие плейлиста)
// использует собственный стек контента [_contentStack] вместо
// Navigator.push — так плейлист открывается внутри окна, а не поверх
// всей раскладки.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../pages/cache_page.dart';
import '../pages/history_page.dart';
import '../pages/playlist_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import 'desktop_home_page.dart';

/// Разделы боковой панели. Добавление нового раздела = новая константа
/// здесь + виджет в IndexedStack в [_DesktopShellState.build].
enum DesktopSection {
  playlists('Playlists', Icons.library_music_rounded),
  search('Search', Icons.search_rounded),
  history('History', Icons.history_rounded),
  cache('Cache', Icons.download_rounded),
  settings('Settings', Icons.settings_rounded);

  const DesktopSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Корневой виджет десктопного приложения.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  DesktopSection _section = DesktopSection.playlists;

  /// Стек открытых «страниц» внутри контентной области. Пока пуст —
  /// показывается IndexedStack разделов; иначе поверх — последний элемент
  /// (например, PlaylistPage), а наверх контента выводится кнопка «назад».
  final List<Widget> _contentStack = [];

  void _openPlaylist(String playlistId) {
    setState(() {
      _contentStack.add(
        PlaylistPage(playlistId: playlistId, showNowPlayingOverlay: false),
      );
    });
  }

  void _closeContent() {
    setState(() => _contentStack.removeLast());
  }

  void _selectSection(DesktopSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      // При смене раздела закрываем открытые вложенные страницы.
      _contentStack.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    final Widget content;
    if (_contentStack.isEmpty) {
      content = IndexedStack(
        index: _section.index,
        children: [
          DesktopHomePage(onOpenPlaylist: _openPlaylist),
          const SearchPage(showNowPlayingOverlay: false),
          const HistoryPage(showNowPlayingOverlay: false),
          const CachePage(),
          const SettingsPage(),
        ],
      );
    } else {
      content = _contentStack.last;
    }

    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NavRail(
                  selected: _section,
                  onSelect: _selectSection,
                  colors: colors,
                  showBack: _contentStack.isNotEmpty,
                  onBack: _closeContent,
                ),
                VerticalDivider(width: 1, color: colors.outline),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Боковая панель навигации (классика: иконка + подпись, всегда раскрыта).
class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.selected,
    required this.onSelect,
    required this.colors,
    required this.showBack,
    required this.onBack,
  });

  final DesktopSection selected;
  final ValueChanged<DesktopSection> onSelect;
  final AppColors colors;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: colors.elevatedVariant,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Логотип / название приложения.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Row(
              children: [
                Icon(Icons.music_note_rounded,
                    color: colors.textPrimary, size: 24),
                const SizedBox(width: 10),
                Text(
                  'Player',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          // Кнопка «назад» — показывается, когда открыта вложенная
          // страница (плейлист). Десктопный аналог AppBar-leading.
          if (showBack)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onBack,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.arrow_back_rounded,
                            color: colors.textPrimary, size: 22),
                        const SizedBox(width: 12),
                        Text(
                          'Back',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          for (final s in DesktopSection.values)
            _NavItem(
              section: s,
              selected: s == selected,
              colors: colors,
              onTap: () => onSelect(s),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final DesktopSection section;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? colors.textPrimary : colors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? colors.outline : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(section.icon, color: fg, size: 22),
                const SizedBox(width: 12),
                Text(
                  section.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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


