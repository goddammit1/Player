import 'package:flutter/material.dart';

/// Общее состояние «живого» предпросмотра перестановки плейлистов.
///
/// Scope поднимается над сеткой плейлистов (мобильная и десктопная
/// главные страницы) и хранит индекс перетаскиваемой карточки
/// ([draggingIndex]) и индекс карточки, над которой сейчас находится
/// указатель ([hoverIndex]). Карточки [ReorderablePlaylistCard] читают
/// scope через [PlaylistReorderScope.maybeOf] и плавно разъезжаются,
/// показывая будущую позицию элемента ещё до drop.
///
/// Параметры сетки ([crossAxisCount], [mainAxisSpacing],
/// [crossAxisSpacing]) нужны для перевода сдвига «на одну ячейку»
/// в долевой translation (см. [ReorderablePlaylistCard]).
class PlaylistReorderScope extends StatefulWidget {
  const PlaylistReorderScope({
    super.key,
    required this.crossAxisCount,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    this.itemExtent,
    required this.child,
  });

  /// Число колонок сетки, над которой висит scope.
  final int crossAxisCount;

  /// Количество ПЕРЕТАСКИВАЕМЫХ элементов (плейлистов) в сетке.
  /// Используется как верхняя граница при маппинге «ячейка под курсором»:
  /// хвостовые не-drag ячейки (например, «Add new») не становятся целью
  /// preview. null — граница не ограничена.
  final int? itemExtent;

  /// Вертикальный зазор между ячейками (px).
  final double mainAxisSpacing;

  /// Горизонтальный зазор между ячейками (px).
  final double crossAxisSpacing;

  final Widget child;

  /// Найти ближайший scope. Возвращает null, если карточка используется
  /// вне сетки с preview (например, в изолированных тестах) — в этом
  /// случае сдвиг соседей просто отключён.
  static PlaylistReorderScopeState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_PlaylistReorderInherited>()
        ?.state;
  }

  @override
  State<PlaylistReorderScope> createState() => PlaylistReorderScopeState();
}

class PlaylistReorderScopeState extends State<PlaylistReorderScope> {
  /// Индекс карточки, которую сейчас перетаскивают (null — drag не активен).
  int? draggingIndex;

  /// Индекс карточки, над которой находится указатель (null — нет цели).
  int? hoverIndex;

  /// Начало drag карточки с индексом [index].
  void startDrag(int index) {
    if (draggingIndex == index) return;
    setState(() {
      draggingIndex = index;
      hoverIndex = null;
    });
  }

  /// Указатель вошёл над карточку с индексом [index].
  ///
  /// [index] МОЖЕТ равняться [draggingIndex]: перетаскиваемая карточка
  /// остаётся в дереве как полупрозрачная «дырка» (childWhenDragging) и
  /// тоже является DragTarget. Hover над «дыркой» — валидное состояние
  /// «вернуть как было»: карточки трактуют hover == dragging как
  /// «без сдвига» (Offset.zero), поэтому все preview-смещения откатываются.
  /// Без этого фильтр «index == draggingIndex» залипал preview на
  /// последней чужой карточке при возврате курсора к исходной ячейке
  /// (соседи не возвращались → визуальное наложение).
  void setHover(int index) {
    if (hoverIndex == index) return;
    setState(() => hoverIndex = index);
  }

  /// Завершение drag (drop или отмена) — состояние чистится полностью.
  /// Вызывается из onAcceptWithDetails, onDragEnd и onDraggableCanceled,
  /// поэтому уход указателя за пределы сетки не оставляет «залипший»
  /// hoverIndex.
  void endDrag() {
    if (draggingIndex == null && hoverIndex == null) return;
    setState(() {
      draggingIndex = null;
      hoverIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Снапшот значений кладём в inherited-виджет: state — mutable-объект,
    // поэтому updateShouldNotify сравнивает снимки, а не сам state.
    return _PlaylistReorderInherited(
      state: this,
      draggingIndex: draggingIndex,
      hoverIndex: hoverIndex,
      child: widget.child,
    );
  }
}

class _PlaylistReorderInherited extends InheritedWidget {
  const _PlaylistReorderInherited({
    required this.state,
    required this.draggingIndex,
    required this.hoverIndex,
    required super.child,
  });

  final PlaylistReorderScopeState state;
  final int? draggingIndex;
  final int? hoverIndex;

  @override
  bool updateShouldNotify(_PlaylistReorderInherited oldWidget) =>
      draggingIndex != oldWidget.draggingIndex ||
      hoverIndex != oldWidget.hoverIndex;
}
