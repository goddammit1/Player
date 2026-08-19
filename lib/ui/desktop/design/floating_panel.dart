// lib/ui/desktop/design/floating_panel.dart
//
// Дизайн-система «плавающего» desktop-интерфейса:
// - [FloatingPanel] — универсальная обёртка скруглённой панели с мягкой
//   тенью и отступом от краёв/соседей (из-за этого панели «плавают» на
//   фоне окна).
// - [Hoverable] — анимированная реакция на hover (для будущих карточек,
//   кнопок и элементов списков).
//
// Цвета берутся из AppColors.fixed (lib/core/global_theme_provider.dart),
// чтобы панели оставались консистентными с остальным UI.

import 'package:flutter/material.dart';

import '../../../core/global_theme_provider.dart';
import 'dimens.dart';

/// «Плавающая» скруглённая панель: цветная подложка с border-radius,
/// мягкой тенью и внешним отступом [margin].
///
/// Используется как каркас всех пяти зон desktop-интерфейса (TopBar,
/// левая навигация, контент, Queue/Track, в перспективе — плеер-бар).
class FloatingPanel extends StatelessWidget {
  const FloatingPanel({
    super.key,
    required this.child,
    this.color,
    this.radius = Dimens.radius,
    this.padding,
    this.margin = const EdgeInsets.all(Dimens.gap),
    this.width,
    this.height,
  });

  final Widget child;

  /// Цвет подложки панели. По умолчанию [AppColors.fixed.elevated].
  final Color? color;

  /// Радиус скругления углов панели.
  final double radius;

  /// Внутренний отступ панели.
  final EdgeInsetsGeometry? padding;

  /// Внешний отступ панели (создаёт «зазор» между плавающими панелями).
  final EdgeInsetsGeometry margin;

  /// Ограничение ширины (удобно для боковых колонок фиксированной ширины).
  final double? width;

  /// Ограничение высоты.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? AppColors.fixed.elevated;
    return Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(radius),
        // Мягкая ненавязчивая тень — задаёт «слой» панели над фоном окна.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

/// Анимированная hover-обёртка: на наведении курсора подложка [child]
/// подсвечивается лёгким акцентом, а [content] слегка «светлеет».
///
/// Заготовка для будущих карточек/кнопок: например, [Hoverable] вокруг
/// логотипа в TopBar или вокруг элементов очереди.
///
/// TODO(floating): при необходимости добавить параметры onHover/onTap
/// (InkWell поверх) — сейчас оставлен только визуальный отклик.
class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    required this.child,
    this.onHover,
    this.radius,
    this.padding,
    this.color,
    this.hoverColor,
  });

  /// Содержимое, поверх которого вешается hover-отклик.
  final Widget child;

  /// Колбэк о наведении (например, для подсветки соседних элементов).
  final ValueChanged<bool>? onHover;

  /// Радиус скругления подложки при наведении.
  final double? radius;

  /// Внутренний отступ подложки.
  final EdgeInsetsGeometry? padding;

  /// Цвет подложки в спокойном состоянии.
  final Color? color;

  /// Цвет подложки при наведении (лёгкий акцент поверх базового).
  final Color? hoverColor;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color ?? AppColors.fixed.elevatedVariant;
    final hover = widget.hoverColor ?? AppColors.fixed.elevatedHi;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHover?.call(false);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: _hovered ? hover.withValues(alpha: 0.18) : base,
          borderRadius: BorderRadius.circular(widget.radius ?? Dimens.radiusCard),
        ),
        // Лёгкое «осветление» контента при наведении.
        foregroundDecoration: BoxDecoration(
          color: _hovered
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(widget.radius ?? Dimens.radiusCard),
        ),
        child: widget.child,
      ),
    );
  }
}