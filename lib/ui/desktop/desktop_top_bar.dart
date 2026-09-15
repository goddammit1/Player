// lib/ui/desktop/desktop_top_bar.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'design/dimens.dart';

/// Верхняя зона: круглая кнопка логотипа + широкая капсула поиска с динамической темой.
class DesktopTopBar extends ConsumerStatefulWidget {
  const DesktopTopBar({super.key});

  @override
  ConsumerState<DesktopTopBar> createState() => _DesktopTopBarState();
}

class _DesktopTopBarState extends ConsumerState<DesktopTopBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(searchProvider).query;
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSubmitted(String value) {
    final q = value.trim();
    if (q.isEmpty) return;
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
    final isFocused = _focus.hasFocus;

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
            child: GestureDetector(
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
            ),
          ),
        ],
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