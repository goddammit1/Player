// lib/ui/desktop/desktop_top_bar.dart
//
// Верхняя зона «плавающего» desktop-интерфейса:
// слева — круглый логотип-нота (с маленькой акцентной точкой), по центру —
// единая строка поиска DesktopSearchBar (TextField).
//
// Строка поиска — настоящий TextField: ввод сразу пишет в searchProvider,
// Enter запускает поиск по всем источникам и сохраняет запрос в историю.
//
// В отличие от мобильной версии здесь НЕТ кнопки-заглушки «Search»,
// которая открывала бы страницу поиска со второй строкой ввода: строка
// в верхней панели — единственная точка входа в поиск на десктопе.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'design/dimens.dart';
import 'design/floating_panel.dart';

/// Верхняя панель desktop-интерфейса. Обёрнута в [FloatingPanel] по
/// горизонтали (зазор от краёв окна).
class DesktopTopBar extends ConsumerStatefulWidget {
  const DesktopTopBar({
    super.key,
    this.accentColor,
  });

  /// Акцентная точка на логотипе. По умолчанию — красноватый оттенок,
  /// контрастный к тёмной подложке приложения.
  final Color? accentColor;

  @override
  ConsumerState<DesktopTopBar> createState() => _DesktopTopBarState();
}

class _DesktopTopBarState extends ConsumerState<DesktopTopBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Если в searchProvider уже есть запрос (например, пользователь вернулся
    // в раздел с незакрытым поиском) — подхватываем его в строку.
    _controller.text = ref.read(searchProvider).query;
  }

  @override
  void dispose() {
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
    final accent = widget.accentColor ?? const Color(0xFFE5484D);
    return FloatingPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: Dimens.pad,
        vertical: Dimens.gap,
      ),
      child: Row(
        children: [
          // Логотип-нота: круг на elevated-подложке + акцентная точка.
          _LogoNote(accentColor: accent),
          const SizedBox(width: Dimens.gap),
          // Единая строка поиска, растянутая по ширине.
          Expanded(
            child: DesktopSearchBar(
              controller: _controller,
              focusNode: _focus,
              onChanged: (_) {},
              onSubmitted: _onSubmitted,
              onClear: _onClear,
            ),
          ),
        ],
      ),
    );
  }
}

/// Круглый логотип-нота: круг с белой нотой внутри и маленькой акцентной
/// точкой в углу (символ «играет»/статуса воспроизведения).
class _LogoNote extends StatelessWidget {
  const _LogoNote({required this.accentColor});

  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      radius: Dimens.gap,
      color: AppColors.fixed.elevated,
      hoverColor: AppColors.fixed.elevatedHi,
      padding: const EdgeInsets.all(Dimens.gapSmall),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Подложка круга.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.fixed.elevated,
              ),
            ),
            // Белая нота.
            Icon(
              Icons.music_note_rounded,
              color: AppColors.fixed.textPrimary,
              size: 24,
            ),
            // Маленькая акцентная точка (правый нижний угол).
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor,
                  border: Border.all(
                    color: AppColors.fixed.elevated,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Настоящее поле поиска в верхней панели: иконка, TextField, кнопка
/// очистки. Ввод сразу пишет в searchProvider (через [onChanged]),
/// Enter запускает поиск (через [onSubmitted]), крестик очищает строку.
///
/// В отличие от мобильного _SearchPill это НЕ кнопка-переход на страницу
/// поиска, а рабочая строка ввода.
class DesktopSearchBar extends StatelessWidget {
  const DesktopSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.fixed.elevated,
      borderRadius: BorderRadius.circular(Dimens.radiusPill),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(
              Icons.search_rounded,
              color: AppColors.fixed.textSecondary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                style: TextStyle(
                  color: AppColors.fixed.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(
                    color: AppColors.fixed.textTertiary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
            // Кнопка очистки — только когда есть текст.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, child) {
                if (value.text.isEmpty) return const SizedBox(width: 12);
                return IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: AppColors.fixed.textSecondary,
                    size: 20,
                  ),
                  tooltip: 'Clear',
                  onPressed: onClear,
                );
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}