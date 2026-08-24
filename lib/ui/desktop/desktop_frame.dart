// lib/ui/desktop/desktop_frame.dart
//
// Десктопная рамка: [Navigator] (child) сверху + [DesktopPlayerBar] снизу.
// Расположение поверх всех маршрутов гарантирует, что панель не скрывается
// при push Settings/SearchHistory из поиска.
//
// ВАЖНО: builder' MaterialApp находится ВЫШЕ Navigator'а, поэтому у панели
// нет ни Material-предка (Slider без него падает «No Material widget found»),
// ни Overlay — а Slider во Flutter 3.4x сам использует OverlayPortal (value
// indicator) и без Overlay кидает «No Overlay widget found» на КАЖДОЙ
// пересборке (десятки ошибок в run_exe_log.txt), а вместо трека рисует
// гигантскую серую плашку (именно «залитый слайдер» из багрепорта).
// Поэтому панель оборачивается в Material + собственный Overlay.
//
// Фаза 3: вынесено из lib/main.dart, чтобы точка входа не содержала
// UI-сборки (desktop-специфика остаётся в lib/ui/desktop/).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'desktop_player_bar.dart';

/// Десктопная рамка вокруг содержимого MaterialApp.
///
/// [child] — Navigator с текущим маршрутом (передаётся из
/// `MaterialApp.builder`).
class DesktopFrame extends ConsumerWidget {
  const DesktopFrame({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    return Material(
      color: colors.background,
      child: Column(
        children: [
          Expanded(child: child ?? const SizedBox.shrink()),
          SizedBox(
            height: DesktopPlayerBar.height,
            child: Overlay(
              initialEntries: [
                // DesktopPlayerBar сам читает провайдеры, поэтому закрытие
                // entry не устаревает при смене палитры.
                OverlayEntry(builder: (_) => const DesktopPlayerBar()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}