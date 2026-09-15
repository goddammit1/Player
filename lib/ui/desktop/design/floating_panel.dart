// lib/ui/desktop/design/floating_panel.dart

import 'package:flutter/material.dart';
import '../../../core/providers/global_theme_provider.dart';
import 'dimens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';

/// «Плавающая» скруглённая островная панель Bento Grid.
class FloatingPanel extends ConsumerWidget {
  const FloatingPanel({
    super.key,
    required this.child,
    this.color,
    this.radius = Dimens.radius,
    this.padding,
    this.margin = EdgeInsets.zero,
    this.width,
    this.height,
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry margin;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final effectiveColor = color ?? colors.elevated;
    return Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

/// Hoverable элемент со скруглением и плавной анимацией подсветки.
class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    required this.child,
    this.onTap,
    this.onHover,
    this.radius,
    this.padding,
    this.color,
    this.hoverColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHover;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final Color? hoverColor;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color ?? Colors.transparent;
    final hover = widget.hoverColor ?? Colors.white.withValues(alpha: 0.08);

    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHover?.call(false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _hovered ? hover : base,
            borderRadius: BorderRadius.circular(widget.radius ?? Dimens.radiusCard),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}