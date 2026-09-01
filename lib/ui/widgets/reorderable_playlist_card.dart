import 'package:flutter/material.dart';

import 'playlist_reorder_scope.dart';

/// Обёртка карточки плейлиста: long-press drag + drop-target + «живой»
/// предпросмотр перестановки.
///
/// Используется на главной (мобильной и десктопной) для ручного
/// переупорядочивания плейлистов перетаскиванием. Семантика индексов в
/// [onReorder] — как у `ReorderableListView.onReorder`: `newIndex`
/// указывает позицию ПОСЛЕ удаления элемента (коррекцию делает
/// `PlaylistRepository.reorderPlaylists`).
///
/// `data` у draggable — индекс плейлиста в списке (int).
///
/// Если над сеткой есть [PlaylistReorderScope], карточка участвует в
/// живом preview: во время drag соседние карточки плавно разъезжаются
/// (см. [_previewTranslation]), показывая будущую позицию до drop.
/// Без scope карточка работает как раньше (preview отключён).
///
/// Обычный тап продолжает работать: `LongPressDraggable` стартует drag
/// только после удержания, короткий тап проходит к `InkWell.onTap` внутри
/// [child].
///
/// TODO(reorder): автоскролл сетки при поднесении перетаскиваемой карточки
/// к краю viewport не реализован — добавить при необходимости.
class ReorderablePlaylistCard extends StatelessWidget {
  const ReorderablePlaylistCard({
    super.key,
    required this.index,
    required this.child,
    required this.onReorder,
  });

  /// Позиция карточки в списке плейлистов.
  final int index;

  /// Содержимое карточки (сам `_PlaylistCard`).
  final Widget child;

  /// Колбэк перестановки: `(oldIndex, newIndex)` — семантика как у
  /// `ReorderableListView.onReorder` (newIndex — после удаления).
  final void Function(int oldIndex, int newIndex) onReorder;

  /// Длительность анимации сдвига соседних карточек при preview.
  static const Duration shiftDuration = Duration(milliseconds: 200);

  /// Целевой сдвиг этой карточки в ДОЛЯХ размера ячейки с учётом
  /// зазоров: `Offset.zero`, если сдвига нет. Логика «разъезжания»:
  ///  - drag вперёд (draggingIndex < hoverIndex): карточки в интервале
  ///    (draggingIndex, hoverIndex] смещаются на одну ячейку НАЗАД
  ///    (на место index - 1), освобождая «дырку» на позиции hoverIndex;
  ///  - drag назад (hoverIndex < draggingIndex): карточки в интервале
  ///    [hoverIndex, draggingIndex) смещаются на одну ячейку ВПЕРЁД
  ///    (на место index + 1);
  ///  - перетаскиваемая карточка не сдвигается (её место — «дырка»).
  ///
  /// Перевод «index ± 1» в 2D-offset: старая и новая (row, col) ячейки
  /// считаются через crossAxisCount; разность (dCol, dRow) умножается
  /// на долю ячейки с учётом spacing: горизонтальная доля =
  /// (cellWidth + crossAxisSpacing) / cellWidth, вертикальная =
  /// (cellHeight + mainAxisSpacing) / cellHeight.
  Offset _previewTranslation(
    PlaylistReorderScopeState scope,
    double cellWidth,
    double cellHeight,
  ) {
    final dragging = scope.draggingIndex;
    final hover = scope.hoverIndex;
    if (dragging == null || hover == null || hover == dragging) {
      return Offset.zero;
    }
    if (index == dragging) return Offset.zero;

    final int targetCell;
    if (dragging < hover) {
      if (index <= dragging || index > hover) return Offset.zero;
      targetCell = index - 1;
    } else {
      if (index < hover || index >= dragging) return Offset.zero;
      targetCell = index + 1;
    }

    final cols = scope.widget.crossAxisCount;
    final oldRow = index ~/ cols;
    final oldCol = index % cols;
    final newRow = targetCell ~/ cols;
    final newCol = targetCell % cols;

    final fx = (newCol - oldCol) *
        ((cellWidth + scope.widget.crossAxisSpacing) / cellWidth);
    final fy = (newRow - oldRow) *
        ((cellHeight + scope.widget.mainAxisSpacing) / cellHeight);
    return Offset(fx, fy);
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder нужен и для ширины feedback (draggable визуально
    // отрывается от layout'а, и без явной ширины feedback получил бы
    // unbounded-констрейнты), и для точных размеров ячейки — из них
    // считается долевой translation с учётом spacing.
    return LayoutBuilder(
      builder: (context, constraints) {
        final scope = PlaylistReorderScope.maybeOf(context);
        final translation =
            (scope != null &&
                constraints.maxWidth.isFinite &&
                constraints.maxHeight.isFinite &&
                constraints.maxWidth > 0 &&
                constraints.maxHeight > 0)
            ? _previewTranslation(
                scope,
                constraints.maxWidth,
                constraints.maxHeight,
              )
            : Offset.zero;

        return DragTarget<int>(
          // Принимаем и «саму себя» (details.data == index): перетаскиваемая
          // карточка остаётся в дереве как полупрозрачная «дырка», и hover
          // над ней — валидное состояние «вернуть как было». onMove у такой
          // цели вызывается (Flutter доставляет didMove всем entered-целям,
          // включая отклонившие — но принятие делает это гарантированным),
          // scope получает setHover(draggingIndex), и preview откатывается
          // в Offset.zero. Реальный drop на себя — no-op (см. onAccept ниже),
          // поэтому результат перестановки не меняется.
          onWillAcceptWithDetails: (details) => true,
          onMove: (details) {
            // Палец/курсор вошёл над эту карточку — фиксируем цель preview.
            // onMove стреляет на каждом pointer-move, поэтому дешёвый
            // setHover с guard'ом на повтор (внутри scope) важен.
            scope?.setHover(index);
          },
          // onLeave сознательно НЕ сбрасывает hoverIndex: иначе карточки
          // «прыгали» бы назад при прохождении зазоров между ячейками.
          // Состояние в любом случае чистится в endDrag (accept/end/cancel).
          onAcceptWithDetails: (details) {
            final oldI = details.data;
            // Drop на собственную «дырку» (oldI == index): цель принята
            // (чтобы hover доходил), но перестановки нет — чистим preview.
            if (oldI != index) {
              // «Вставить на позицию цели»: при переносе вниз (oldI < index)
              // после удаления oldI позиция цели смещается на +1 — элемент
              // встаёт ровно на место цели.
              onReorder(oldI, oldI < index ? index + 1 : index);
            }
            scope?.endDrag();
          },
          builder: (context, candidateData, rejectedData) {
            final highlighted = candidateData.isNotEmpty;
            // AnimatedSlide = FractionalTranslation с неявной анимацией:
            // offset задан в ДОЛЯХ собственного размера карточки, что
            // позволяет перевести «сдвиг на одну ячейку» в translation без
            // привязки к абсолютным пикселям (spacing учтён в долях).
            return AnimatedSlide(
              offset: translation,
              duration: shiftDuration,
              curve: Curves.easeOutCubic,
              child: LongPressDraggable<int>(
                data: index,
                feedback: _DragFeedback(
                  width: constraints.maxWidth,
                  child: child,
                ),
                childWhenDragging: Opacity(opacity: 0.25, child: child),
                onDragStarted: () => scope?.startDrag(index),
                // onDragEnd стреляет и после drop, и после отмены жеста —
                // гарантированная очистка preview-состояния. Порядок
                // вызовов: onAcceptWithDetails (до onDragEnd) уже вызвал
                // onReorder, повторный endDrag безопасен (guard внутри).
                onDragEnd: (_) => scope?.endDrag(),
                onDraggableCanceled: (_, _) => scope?.endDrag(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: highlighted
                      ? BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        )
                      : const BoxDecoration(),
                  child: child,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// «Призрак» карточки под пальцем/курсором: уменьшенная полупрозрачная
/// копия в `Material` с тенью. Ширина фиксирована (ширина ячейки сетки),
/// чтобы feedback не получал бесконечные констрейнты вне layout'а.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Opacity(
        opacity: 0.9,
        child: Transform.scale(
          scale: 0.92,
          child: Material(
            elevation: 8,
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ),
    );
  }
}
