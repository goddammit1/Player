// lib/ui/desktop/design/dimens.dart
//
// Дизайн-система десктопного «плавающего» интерфейса: единые отступы,
// радиусы и высоты. Всё, что связано с размерами в новом desktop-UI,
// берётся отсюда, чтобы не плодить «магические числа».

/// Единые размеры «плавающего» desktop-интерфейса (5 зон: TopBar,
/// навигация, контент, Queue/Track, плеер-бар).
abstract final class Dimens {
  /// Базовый зазор между плавающими панелями.
  static const double gap = 12.0;

  /// Малый зазор внутри панелей (между элементами).
  static const double gapSmall = 8.0;

  /// Стандартный внутренний отступ панелей.
  static const double pad = 16.0;

  /// Увеличенный внутренний отступ (заголовки, крупные секции).
  static const double padLarge = 24.0;

  /// Радиус скругления крупных «плавающих» панелей (TopBar, зоны).
  static const double radius = 20.0;

  /// Радиус скругления вложенных карточек (карточки треков, блоки).
  static const double radiusCard = 16.0;

  /// Радиус pill-элементов (поиск, табы, кнопки-таблетки).
  static const double radiusPill = 32.0;

  /// Радиус скругления элементов боковой навигации.
  static const double navItemRadius = 12.0;

  /// Высота нижней панели плеера (см. DesktopPlayerBar.height в
  /// lib/ui/desktop/desktop_player_bar.dart).
  static const double playerBarHeight = 88.0;
}