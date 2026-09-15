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
import 'design/dimens.dart';
import 'desktop_player_bar.dart';

class DesktopFrame extends ConsumerWidget {
  const DesktopFrame({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Динамическая палитра: фон вокруг плеера подстраивается под тему,
    // чёрная кайма вокруг островка исчезает.
    final colors = ref.watch(animatedPaletteProvider);

    return Material(
      color: colors.background, // вместо Colors.black
      child: Column(
        children: [
          Expanded(child: child ?? const SizedBox.shrink()),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Dimens.gap,
              Dimens.gap,
              Dimens.gap,
              Dimens.gap,
            ),
            child: SizedBox(
              height: DesktopPlayerBar.height,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(builder: (_) => const DesktopPlayerBar()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}