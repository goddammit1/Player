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
import '../pages/history_page.dart';
import '../pages/playlist_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import 'design/dimens.dart';
import 'design/floating_panel.dart';
import 'desktop_home_page.dart';
import 'desktop_top_bar.dart';
import 'queue_panel.dart';

/// Разделы боковой панели. Добавление нового раздела = новая константа
/// здесь + виджет в IndexedStack в [_DesktopShellState.build].
///
/// В ТЗ в левой панели остаются только Playlists / History / Settings.
/// Поиск (Search) перенесён в верхнюю строку TopBar, а Cache доступен из
/// настроек (см. _CacheTile в settings_page.dart).
enum DesktopSection {
  playlists('Playlists', Icons.library_music_rounded),
  history('History', Icons.history_rounded),
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
  /// (например, PlaylistPage).
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

  /// Очищает активный поисковый запрос — верхняя строка пустеет, а контент
  /// возвращается к выбранному разделу / открытому плейлисту.
  void _clearSearch() {
    ref.read(searchProvider.notifier).search('');
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

    // Поиск больше не открывается через push страницы: верхняя строка пишет
    // в searchProvider, и как только запрос непустой — контентная область
    // показывает результаты поиска (SearchPage без собственной строки ввода).
    final searchQuery = ref.watch(searchProvider).query.trim();
    final bool isSearching = searchQuery.isNotEmpty;

    final Widget content;
    if (isSearching) {
      content = const SearchPage(
        showNowPlayingOverlay: false,
        showInPageSearchBar: false,
      );
    } else if (_contentStack.isEmpty) {
      content = IndexedStack(
        index: _section.index,
        children: [ // по порядку enum DesktopSection
          DesktopHomePage(onOpenPlaylist: _openPlaylist), // playlists
          const HistoryPage(showNowPlayingOverlay: false), // history
          const SettingsPage(), // settings
        ],
      );
    } else {
      content = _contentStack.last;
    }

    // Правая колонка «Queue/Track» на узких окнах скрывается, чтобы контент
    // не сжимался. Вариант B — показывать всегда (раскомментируй ниже):
    //   final bool showQueue = true;
    final bool showQueue =
        MediaQuery.sizeOf(context).width >= _queuePanelMinScreenWidth;

    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          // Зона 1 — верхняя панель (логотип + строка поиска).
          const DesktopTopBar(),
          // Зона 5 — нижний плеер-бар остаётся ВНЕ shell (рисует
          // _DesktopFrame в lib/main.dart). Когда интеграция FloatingPanel
          // будет готова, панель перенесут внутрь, например так:
          //   SizedBox(
          //     height: Dimens.playerBarHeight,
          //     child: FloatingPanel(child: DesktopPlayerBar()),
          //   ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Зона 2 — левая навигация в «плавающей» панели.
                FloatingPanel(
                  padding: EdgeInsets.zero,
                  child: _NavRail(
                    selected: _section,
                    onSelect: _selectSection,
                    colors: colors,
                    // «Назад»: сбрасываем поиск, если он активен; иначе
                    // закрываем открытый плейлист.
                    showBack: isSearching || _contentStack.isNotEmpty,
                    onBack: isSearching ? _clearSearch : _closeContent,
                  ),
                ),
                // Зазор между левой панелью и контентом.
                const SizedBox(width: Dimens.gap),
                // Зона 3 — центральный контент в «плавающей» панели.
                Expanded(
                  child: FloatingPanel(
                    padding: EdgeInsets.zero,
                    child: content,
                  ),
                ),
                if (showQueue) ...[
                  // Зазор между контентом и правой колонкой.
                  const SizedBox(width: Dimens.gap),
                  // Зона 4 — правая колонка «Queue/Track».
                  const QueuePanel(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Минимальная ширина окна, при которой показывается правая колонка
  /// «Queue/Track» (ниже — скрывается, контент растягивается).
  static const double _queuePanelMinScreenWidth = 1000;
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
    // Цвет подложки задаёт внешняя FloatingPanel (desktop_shell.dart);
    // здесь — прозрачный, чтобы панель скругляла углы навигации.
    return Container(
      width: 220,
      color: Colors.transparent,
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


