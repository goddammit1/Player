// lib/ui/widgets/grouped_tiles.dart
//
// Сгруппированные плитки — общий стиль списков приложения (Cached tracks,
// настройки Soulseek, лист загрузок): каждая плитка — отдельная поверхность
// colors.elevated, внешние углы группы 15, внутренние 5, зазор 2.

import 'package:flutter/material.dart';

import '../../core/providers.dart';

/// Скругление плитки по её позиции в группе.
BorderRadius groupedTileRadius(bool isFirst, bool isLast) =>
    BorderRadius.vertical(
      top: Radius.circular(isFirst ? 15 : 5),
      bottom: Radius.circular(isLast ? 15 : 5),
    );

/// Группа плиток: каждая дочерняя — Material colors.elevated со скруглением
/// по позиции (ripple InkWell'ов внутри обрезается по форме плитки).
class GroupedTiles extends StatelessWidget {
  const GroupedTiles({
    super.key,
    required this.colors,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final AppColors colors;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            Material(
              color: colors.elevated,
              borderRadius: groupedTileRadius(i == 0, i == children.length - 1),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ],
        ],
      ),
    );
  }
}

/// Uppercase-подпись над группой плиток.
class GroupedTilesLabel extends StatelessWidget {
  const GroupedTilesLabel({
    super.key,
    required this.title,
    required this.colors,
    this.top = 24,
  });

  final String title;
  final AppColors colors;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(22, top, 22, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: colors.textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
