import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/artwork_helper.dart';

/// Юнит-тесты для [ArtworkHelper.resolveEffectiveArtwork] — логики выбора
/// эффективной обложки (кастомная пользовательская > fallback-URL).
///
/// Плагины (image_picker, path_provider) здесь не задействуются: кейсы
/// подобраны так, чтобы код шёл по быстрому пути (trackId == null либо
/// кастомная обложка не установлена — _customArtCache пуст).
void main() {
  group('ArtworkHelper.resolveEffectiveArtwork', () {
    test('trackId == null → возвращает fallbackUrl', () {
      expect(
        ArtworkHelper.resolveEffectiveArtwork(
          fallbackUrl: 'https://images.genius.com/a_600x600.png',
          trackId: null,
        ),
        'https://images.genius.com/a_600x600.png',
      );
    });

    test('trackId пустой → возвращает fallbackUrl', () {
      expect(
        ArtworkHelper.resolveEffectiveArtwork(
          fallbackUrl: 'https://images.genius.com/a_600x600.png',
          trackId: '',
        ),
        'https://images.genius.com/a_600x600.png',
      );
    });

    test('trackId без кастомной обложки → возвращает fallbackUrl', () {
      // _customArtCache в тесте пуст — getCustomArtworkSync вернёт null,
      // плагины не вызываются.
      expect(
        ArtworkHelper.resolveEffectiveArtwork(
          fallbackUrl: 'https://images.mzstatic.com/b.jpg',
          trackId: 'youtube:abc123',
        ),
        'https://images.mzstatic.com/b.jpg',
      );
    });

    test('fallbackUrl == null и кастомной нет → null', () {
      expect(
        ArtworkHelper.resolveEffectiveArtwork(
          fallbackUrl: null,
          trackId: 'muzmo:xyz',
        ),
        isNull,
      );
    });
  });
}