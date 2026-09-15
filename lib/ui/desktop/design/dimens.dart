// lib/ui/desktop/design/dimens.dart

/// Единые размеры «плавающего» desktop-интерфейса (Bento Grid).
abstract final class Dimens {
  /// Базовый зазор между плавающими панелями.
  static const double gap = 12.0;

  /// Малый зазор между элементами внутри панелей.
  static const double gapSmall = 8.0;

  /// Стандартный внутренний отступ панелей.
  static const double pad = 16.0;

  /// Увеличенный внутренний отступ (заголовки, крупные секции).
  static const double padLarge = 24.0;

  /// Радиус скругления крупных островных панелей (Playlists, Queue, PlayerBar).
  static const double radius = 32.0;

  /// Радиус скругления карточек (обложки, выделенный активный трек).
  static const double radiusCard = 32.0;

  /// Радиус капсул / пилюль (поиск, табы Queue/Track, пилюли навигации).
  static const double radiusPill = 32.0;

  /// Высота верхней панели поиска.
  static const double topBarHeight = 64.0;

  /// Высота нижней панели плеера.
  static const double playerBarHeight = 96.0;

  /// Ширина левого компактного сайдбара.
  static const double navRailWidth = 76.0;

  /// Ширина правой колонки очереди.
  static const double queuePanelWidth = 340.0;
}