// lib/ui/desktop/desktop_ui_state.dart
//
// Состояние правой панели «Queue / Track», общее для DesktopShell (рисует
// панель) и DesktopPlayerBar (живёт выше Navigator'а и управляет панелью
// кнопкой очереди и кликом по треку).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/dimens.dart';

enum DesktopSideTab { queue, track }

class DesktopSidePanelState {
  const DesktopSidePanelState({
    this.docked = true,
    this.overlayOpen = false,
    this.tab = DesktopSideTab.queue,
  });

  /// Широкое окно: панель стоит колонкой справа от контента.
  final bool docked;

  /// Узкое окно (< [Dimens.queueDockBreakpoint]): панель выезжает оверлеем.
  /// По умолчанию закрыта, чтобы не перекрывать контент при старте.
  final bool overlayOpen;

  final DesktopSideTab tab;

  bool visibleAt(double windowWidth) =>
      windowWidth >= Dimens.queueDockBreakpoint ? docked : overlayOpen;

  DesktopSidePanelState copyWith({
    bool? docked,
    bool? overlayOpen,
    DesktopSideTab? tab,
  }) {
    return DesktopSidePanelState(
      docked: docked ?? this.docked,
      overlayOpen: overlayOpen ?? this.overlayOpen,
      tab: tab ?? this.tab,
    );
  }
}

class DesktopSidePanelNotifier extends StateNotifier<DesktopSidePanelState> {
  DesktopSidePanelNotifier() : super(const DesktopSidePanelState());

  bool _wide(double width) => width >= Dimens.queueDockBreakpoint;

  void _setVisible(double windowWidth, bool visible) {
    state = _wide(windowWidth)
        ? state.copyWith(docked: visible)
        : state.copyWith(overlayOpen: visible);
  }

  void selectTab(DesktopSideTab tab) => state = state.copyWith(tab: tab);

  /// Кнопка очереди в плеер-баре: скрытая панель открывается на «Queue»;
  /// открытая на «Track» переключается на «Queue»; открытая на «Queue» —
  /// закрывается.
  void toggleQueue(double windowWidth) {
    if (!state.visibleAt(windowWidth)) {
      _setVisible(windowWidth, true);
      selectTab(DesktopSideTab.queue);
    } else if (state.tab != DesktopSideTab.queue) {
      selectTab(DesktopSideTab.queue);
    } else {
      _setVisible(windowWidth, false);
    }
  }

  /// Клик по треку в плеер-баре: панель открывается на «Track».
  void showTrack(double windowWidth) {
    _setVisible(windowWidth, true);
    selectTab(DesktopSideTab.track);
  }

  void closeOverlay() => state = state.copyWith(overlayOpen: false);
}

final desktopSidePanelProvider =
    StateNotifierProvider<DesktopSidePanelNotifier, DesktopSidePanelState>(
      (ref) => DesktopSidePanelNotifier(),
    );
