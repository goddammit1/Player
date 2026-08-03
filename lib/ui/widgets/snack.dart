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

/// Зелёный toast для успешных операций.
void showSuccessSnack(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.clearSnackBars();
  m.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle_outline, color: Color(0xFF4CAF50), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
      duration: const Duration(milliseconds: 1500),
    ),
  );
}

/// Красный toast для ошибок.
void showErrorSnack(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.clearSnackBars();
  m.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFEF5350), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
      duration: const Duration(milliseconds: 2500),
    ),
  );
}
