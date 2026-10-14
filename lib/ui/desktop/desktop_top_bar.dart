// lib/ui/desktop/desktop_top_bar.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'design/dimens.dart';
import 'soulseek_downloads_indicator.dart';

/// Верхняя зона: круглая кнопка логотипа + широкая капсула поиска с динамической темой.
class DesktopTopBar extends ConsumerStatefulWidget {
  const DesktopTopBar({super.key});

  @override
  ConsumerState<DesktopTopBar> createState() => _DesktopTopBarState();
}

class _DesktopTopBarState extends ConsumerState<DesktopTopBar> {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  // Выпадающая история поиска: видна при фокусе пустого поля.
  final _historyLink = LayerLink();
  final _historyPortal = OverlayPortalController();

  /// Подсвеченный (стрелками / мышью) запрос; -1 — ничего.
  int _highlight = -1;

  /// Esc закрыл историю — до следующего фокуса или правки текста.
  bool _historyDismissed = false;

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(searchProvider).query;
    _lastText = _controller.text;
    _focus.addListener(_onFocusChange);
    _controller.addListener(_onTextChange);
    // Портал показан всегда, содержимое решает _buildHistory: так не нужно
    // переключать контроллер из build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _historyPortal.show();
    });
  }

  void _onFocusChange() {
    setState(() {
      _historyDismissed = false;
      _highlight = -1;
    });
  }

  String _lastText = '';

  void _onTextChange() {
    final text = _controller.text;
    if (text == _lastText) return; // смена выделения / курсора
    _lastText = text;
    setState(() {
      _historyDismissed = false;
      _highlight = -1;
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _controller.removeListener(_onTextChange);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Запросы выпадающей истории; пустой список — история скрыта.
  List<String> _visibleHistory(List<String> history) {
    if (!_focus.hasFocus || _historyDismissed) return const [];
    if (_controller.text.isNotEmpty) return const [];
    return history;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final items = _visibleHistory(ref.read(searchHistoryProvider));
    if (items.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlight = _highlight <= 0 ? items.length - 1 : _highlight - 1;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _historyDismissed = true;
        _highlight = -1;
      });
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        _highlight >= 0 &&
        _highlight < items.length) {
      _searchFromHistory(items[_highlight]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _searchFromHistory(String query) {
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _onSubmitted(query);
    _focus.unfocus();
  }

  void _onSubmitted(String value) {
    final q = value.trim();
    if (q.isEmpty) {
      // Enter при подсвеченном запросе, если клавишу перехватил IME.
      final items = _visibleHistory(ref.read(searchHistoryProvider));
      if (_highlight >= 0 && _highlight < items.length) {
        _searchFromHistory(items[_highlight]);
      }
      return;
    }
    ref.read(searchProvider.notifier).search(q);
    ref.read(searchHistoryProvider.notifier).add(q);
  }

  void _onClear() {
    _controller.clear();
    ref.read(searchProvider.notifier).search('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    // Поиск сброшен извне (кнопка «назад» в nav rail) — очищаем и поле,
    // иначе история под пустым полем не покажется.
    ref.listen(searchProvider.select((s) => s.query), (_, query) {
      if (query.isEmpty && _controller.text.isNotEmpty) _controller.clear();
    });
    final isFocused = _focus.hasFocus;
    final history = _visibleHistory(ref.watch(searchHistoryProvider));

    return SizedBox(
      height: Dimens.topBarHeight,
      child: Row(
        children: [
          const SizedBox(width: Dimens.gap-4),
          // Левый круглый логотип
          Container(
            width: Dimens.topBarHeight,
            height: Dimens.topBarHeight,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.elevated,
            ),
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.music_note_rounded,
                    color: colors.textPrimary,
                    size: 30,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.elevatedHi,
                        border: Border.all(color: colors.elevated, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Dimens.gap),
          // Поле поиска с анимацией появления обводки 3px цвета elevatedHi
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => OverlayPortal(
                controller: _historyPortal,
                overlayChildBuilder: (_) =>
                    _buildHistory(history, c.maxWidth, colors),
                child: CompositedTransformTarget(
                  link: _historyLink,
                  child: _buildSearchField(colors, isFocused),
                ),
              ),
            ),
          ),
          const SoulseekDownloadsIndicator(),
        ],
      ),
    );
  }

  Widget _buildHistory(List<String> items, double width, AppColors colors) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _historyLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, Dimens.gapSmall),
        // Клик по истории не считается «кликом мимо поля» — фокус остаётся.
        child: TextFieldTapRegion(
          child: SizedBox(
            width: width,
            child: Material(
              key: const Key('search_history_dropdown'),
              color: colors.elevated,
              elevation: 8,
              shadowColor: Colors.black54,
              borderRadius: BorderRadius.circular(Dimens.radiusCard - 8),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Recent searches',
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          TextButton(
                            key: const Key('search_history_clear'),
                            onPressed: () => ref
                                .read(searchHistoryProvider.notifier)
                                .clear(),
                            style: TextButton.styleFrom(
                              foregroundColor: colors.textSecondary,
                              shape: const StadiumBorder(),
                            ),
                            child: const Text('Clear all'),
                          ),
                        ],
                      ),
                    ),
                    for (var i = 0; i < items.length; i++)
                      _HistoryRow(
                        key: ValueKey('search_history_${items[i]}'),
                        query: items[i],
                        highlighted: i == _highlight,
                        colors: colors,
                        onHover: () => setState(() => _highlight = i),
                        onTap: () => _searchFromHistory(items[i]),
                        onRemove: () => ref
                            .read(searchHistoryProvider.notifier)
                            .remove(items[i]),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(AppColors colors, bool isFocused) {
    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: Dimens.topBarHeight,
        padding: const EdgeInsets.only(left: 24, right: 8),
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(Dimens.radiusPill),
          border: Border.all(
            color: isFocused ? colors.elevatedHi : Colors.transparent,
            width: 3.0, // Увеличено до 3px
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                cursorColor: colors.elevatedHi,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 24, // Текст ввода
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 24, // Подсказка увеличена до 24
                    fontWeight: FontWeight.w500,
                  ),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
                onSubmitted: _onSubmitted,
              ),
            ),
            // Кнопка очистки с задним кружком при наведении
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return _ClearButton(
                  colors: colors,
                  onClear: _onClear,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка выпадающей истории: клик — поиск, «×» — удалить запрос.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.query,
    required this.highlighted,
    required this.colors,
    required this.onHover,
    required this.onTap,
    required this.onRemove,
  });

  final String query;
  final bool highlighted;
  final AppColors colors;
  final VoidCallback onHover;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.only(left: 16, right: 4),
          decoration: BoxDecoration(
            color: highlighted
                ? colors.elevatedHi.withValues(alpha: 0.35)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(Dimens.radiusPill),
          ),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 20, color: colors.textSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  query,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textPrimary, fontSize: 16),
                ),
              ),
              IconButton(
                key: ValueKey('search_history_remove_$query'),
                tooltip: 'Remove',
                iconSize: 18,
                color: colors.textSecondary,
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Анимированная кнопка очистки с кружком подложки
class _ClearButton extends StatefulWidget {
  const _ClearButton({
    required this.colors,
    required this.onClear,
  });

  final AppColors colors;
  final VoidCallback onClear;

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final double scale = (_isHovered && !_isPressed) ? 1.10 : 1.0;

    final targetColor = _isHovered
        ? widget.colors.textPrimary
        : widget.colors.textSecondary;

    // Кружок подложки с 50% прозрачности от elevatedHi (как в боковой панели)
    final hoverCircleColor = widget.colors.elevatedHi.withValues(alpha: 0.30);

    return MouseRegion(
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
        onTap: widget.onClear,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1. Задний кружок 32x32 при наведении
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                opacity: _isHovered ? 1.0 : 0.0,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hoverCircleColor,
                  ),
                ),
              ),
              // 2. Иконка с анимацией масштаба (+10% hover, 1.0 press) и цвета
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                child: TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  tween: ColorTween(end: targetColor),
                  builder: (context, color, child) {
                    return Icon(
                      Icons.close_rounded,
                      color: color,
                      size: 24,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}