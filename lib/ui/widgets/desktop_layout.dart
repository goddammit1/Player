// lib/ui/widgets/desktop_layout.dart
//
// Вспомогательные утилиты для минимальной адаптации UI под десктоп
// (Windows/Linux/macOS). ВСЕ ветки гейтятся через [isDesktop], поэтому
// мобильная вёрстка (Android/iOS) остаётся неизменной.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// true на Windows/Linux/macOS (native desktop), false на мобильных и web.
bool get isDesktop {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
    default:
      return false;
  }
}

/// Центрирует [child] по горизонтали и ограничивает его ширину
/// [maxWidth]. На мобильных платформах возвращает [child] как есть,
/// поэтому десктопные ограничения не влияют на Android/iOS.
Widget desktopCentered(
  Widget child, {
  double maxWidth = 760,
  AlignmentGeometry alignment = Alignment.center,
}) {
  if (!isDesktop) return child;
  return Align(
    alignment: alignment,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Обёртка над [showModalBottomSheet], которая на десктопе ограничивает
/// ширину шторки по центру экрана. На мобильных поведение идентично
/// стандартному вызову.
Future<T?> showDesktopModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 520,
  Color? backgroundColor,
  bool isScrollControlled = true,
  bool useRootNavigator = true,
  bool showDragHandle = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    showDragHandle: showDragHandle,
    builder: (sheetCtx) {
      final sheet = builder(sheetCtx);
      if (!isDesktop) return sheet;
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: sheet,
        ),
      );
    },
  );
}
