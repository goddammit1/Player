// lib/ui/desktop/desktop_shell.dart

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

enum DesktopSection {
  playlists('Playlists', Icons.library_music_rounded),
  history('History', Icons.history_rounded),
  settings('Settings', Icons.settings_rounded);

  const DesktopSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  DesktopSection _section = DesktopSection.playlists;
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

  void _clearSearch() {
    ref.read(searchProvider.notifier).search('');
  }

  void _selectSection(DesktopSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _contentStack.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Подписка на динамическую палитру
    final colors = ref.watch(animatedPaletteProvider);

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
        children: [
          DesktopHomePage(onOpenPlaylist: _openPlaylist),
          const HistoryPage(showNowPlayingOverlay: false),
          const SettingsPage(),
        ],
      );
    } else {
      content = _contentStack.last;
    }

    final bool showQueue = MediaQuery.sizeOf(context).width >= 960;

    return Scaffold(
      backgroundColor: colors.background,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
          Dimens.gap,
          Dimens.gap,
          Dimens.gap,
          0,
        ),
        child: Column(
          children: [
            // 1. Верхний бар
            const DesktopTopBar(),
            const SizedBox(height: Dimens.gap),
            // 2. Центральная область: сайдбар + контент + очередь
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: Dimens.navRailWidth,
                    child: _CompactNavRail(
                      selected: _section,
                      onSelect: _selectSection,
                      colors: colors,
                      showBack: isSearching || _contentStack.isNotEmpty,
                      onBack: isSearching ? _clearSearch : _closeContent,
                    ),
                  ),
                  const SizedBox(width: Dimens.gap),
                  Expanded(
                    child: FloatingPanel(
                      padding: EdgeInsets.zero,
                      child: content,
                    ),
                  ),
                  if (showQueue) ...[
                    const SizedBox(width: Dimens.gap),
                    const QueuePanel(width: Dimens.queuePanelWidth),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Компактная вертикальная навигация
class _CompactNavRail extends StatelessWidget {
  const _CompactNavRail({
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
    return Column(
      children: [
        if (showBack)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: IconButton(
              icon: Icon(
                Icons.arrow_back_rounded,
                color: colors.textPrimary,
                size: 24,
              ),
              onPressed: onBack,
            ),
          ),
        for (final s in DesktopSection.values)
          _CompactNavItem(
            key: ValueKey('nav_item_${s.name}'),
            section: s,
            selected: s == selected,
            colors: colors,
            onTap: () => onSelect(s),
          ),
      ],
    );
  }
}

/// Элемент навигации с динамическими цветами и анимациями
class _CompactNavItem extends StatefulWidget {
  const _CompactNavItem({
    super.key,
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
  State<_CompactNavItem> createState() => _CompactNavItemState();
}

class _CompactNavItemState extends State<_CompactNavItem>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isPressed = false;

  late final AnimationController _selectAnimController;
  late final Animation<double> _pillWidthAnim;
  late final Animation<double> _selectOpacityAnim;

  @override
  void initState() {
    super.initState();
    _selectAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: widget.selected ? 1.0 : 0.0,
    );

    // Раскрытие selected пилюли от 32px до 56px
    _pillWidthAnim = Tween<double>(begin: 32.0, end: 56.0).animate(
      CurvedAnimation(
        parent: _selectAnimController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    // Плавное появление непрозрачности selected слоя
    _selectOpacityAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _selectAnimController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        reverseCurve: const Interval(0.0, 1.0, curve: Curves.easeIn),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _CompactNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected && widget.selected) {
      _selectAnimController.forward(from: 0.0);
    } else if (oldWidget.selected && !widget.selected) {
      _selectAnimController.reverse();
    }
  }

  @override
  void dispose() {
    _selectAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Цвета берутся из переданной динамической темы
    final selectedColor = widget.colors.elevatedHi;
    final hoverColor = selectedColor.withValues(alpha: 0.30);

    // Иконка масштабируется на 10% при наведении, при зажатии возвращается к 1.0
    final double iconScale = (_isHovered && !_isPressed) ? 1.10 : 1.0;

    final Color foregroundColor = widget.selected || _isHovered
        ? widget.colors.textPrimary
        : widget.colors.textSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() {
          _isHovered = false;
          _isPressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: widget.onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 32,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 1. Слой Hover-пилюли (56x32px, 50% прозрачности от elevatedHi)
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      opacity: _isHovered ? 1.0 : 0.0,
                      child: Container(
                        width: 56,
                        height: 32,
                        decoration: BoxDecoration(
                          color: hoverColor,
                          borderRadius: BorderRadius.circular(Dimens.radiusPill),
                        ),
                      ),
                    ),

                    // 2. Слой Selected-пилюли (раскрывается от 32x32px до 56x32px поверх hover)
                    AnimatedBuilder(
                      animation: _selectAnimController,
                      builder: (context, child) {
                        if (_selectOpacityAnim.value == 0.0) {
                          return const SizedBox.shrink();
                        }
                        return Opacity(
                          opacity: _selectOpacityAnim.value,
                          child: Container(
                            width: _pillWidthAnim.value,
                            height: 32,
                            decoration: BoxDecoration(
                              color: selectedColor,
                              borderRadius: BorderRadius.circular(Dimens.radiusPill),
                            ),
                          ),
                        );
                      },
                    ),

                    // 3. Иконка с анимацией масштаба (hover -> 1.14, press -> 1.0)
                    AnimatedScale(
                      scale: iconScale,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        widget.section.icon,
                        color: foregroundColor,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Подпись под иконкой
              Text(
                widget.section.label,
                style: TextStyle(
                  color: foregroundColor,
                  fontSize: 12,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


