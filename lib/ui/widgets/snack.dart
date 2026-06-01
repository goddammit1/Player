import 'package:flutter/material.dart';

/// Короткие тосты в одном стиле.
///
/// Дефолтный `Duration` у материального `SnackBar` — 4 секунды. Это
/// слишком долго для подтверждений типа «added to playlist», и
/// пользователь жалуется, что белые «coming soon» сообщения долго
/// маячат. Используем 1.2 секунды.
///
/// Цвета берутся из `Theme.of(context).snackBarTheme` (см. main.dart).
void showSnack(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.clearSnackBars();
  m.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1200),
    ),
  );
}
