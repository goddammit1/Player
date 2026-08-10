@Tags(['unit'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/artwork_provider.dart';

/// Офлайн-тесты для _extractVersionHints — извлечения версионных хинтов
/// из заголовков треков для улучшения поиска обложек ремиксов.
///
/// Запуск:
///   flutter test --tags unit test/sources/artwork_provider_test.dart
void main() {
  group('isProviderArtworkUrl', () {
    test('Genius URL считается провайдерской обложкой', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl(
          'https://images.genius.com/abc_600x600.png',
        ),
        isTrue,
      );
    });

    test('iTunes (mzstatic) URL считается провайдерской обложкой', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl(
          'https://is1-ssl.mzstatic.com/image/thumb/xyz.jpg',
        ),
        isTrue,
      );
    });

    test('SoundCloud (sndcdn) — обложка источника, не провайдерская', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl(
          'https://i1.sndcdn.com/artworks-0001-t500x500.jpg',
        ),
        isFalse,
      );
    });

    test('YouTube (ytimg) — обложка источника, не провайдерская', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl(
          'https://i.ytimg.com/vi/abc/hqdefault.jpg',
        ),
        isFalse,
      );
    });

    test('локальные пути не провайдерские', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl('/data/player/art/1.jpg'),
        isFalse,
      );
      expect(
        ArtworkProvider.isProviderArtworkUrl('file:///data/player/art/1.jpg'),
        isFalse,
      );
    });

    test('пустая строка не провайдерская', () {
      expect(ArtworkProvider.isProviderArtworkUrl(''), isFalse);
    });

    test('регистр домена не важен', () {
      expect(
        ArtworkProvider.isProviderArtworkUrl(
          'https://images.GENIUS.com/abc_600x600.png',
        ),
        isTrue,
      );
    });
  });


  group('_extractVersionHints', () {
    test('Remix в круглых скобках', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Исчезаю (Remix)');
      expect(r.cleanTitle, 'Исчезаю');
      expect(r.versionHints, ['Remix']);
    });

    test('Remix — регистр не важен', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (REMIX)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['REMIX']);
    });

    test('Dancecore Remix', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Dancecore Remix)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Dancecore Remix']);
    });

    test('feat отфильтровывается, Radio Edit — остаётся', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (feat. X) (Radio Edit)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Radio Edit']);
    });

    test('feat + prod. by — отфильтровывается', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Track (feat. John) (prod. by Mike)',
      );
      expect(r.cleanTitle, 'Track');
      expect(r.versionHints, isEmpty);
    });

    test('Official Video — шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Official Video)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, isEmpty);
    });

    test('official audio — шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Track (official audio)');
      expect(r.cleanTitle, 'Track');
      expect(r.versionHints, isEmpty);
    });

    test('клип (кириллица) — шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Песня (клип)');
      expect(r.versionHints, isEmpty);
    });

    test('Original Mix — шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Track (Original Mix)');
      expect(r.versionHints, isEmpty);
    });

    test('Album Version — шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Album Version)');
      expect(r.versionHints, isEmpty);
    });

    test('Суффикс через тире — " - Remix"', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Track - Remix');
      expect(r.cleanTitle, 'Track');
      expect(r.versionHints, ['Remix']);
    });

    test('Суффикс — " - Extended Mix"', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Track - Extended Mix');
      expect(r.cleanTitle, 'Track');
      expect(r.versionHints, ['Extended Mix']);
    });

    test('Квадратные скобки [Slowed + Reverb]', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song [Slowed + Reverb]');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Slowed + Reverb']);
    });

    test('Обычная песня без скобок', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Обычная песня');
      expect(r.cleanTitle, 'Обычная песня');
      expect(r.versionHints, isEmpty);
    });

    test('Пустой заголовок', () {
      final r = ArtworkProvider.extractVersionHintsForTest('');
      expect(r.cleanTitle, '');
      expect(r.versionHints, isEmpty);
    });

    test('Только скобки с шумом', () {
      final r = ArtworkProvider.extractVersionHintsForTest('(Official Video)');
      expect(r.versionHints, isEmpty);
    });

    test('Несколько скобок, один Remix', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Song (prod. by X) (Remix) (Official Audio)',
      );
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Remix']);
    });

    test('Club Mix | Extended Mix — оба варианта', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Club Mix | Extended Mix)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Club Mix', 'Extended Mix']);
    });

    test('Дубликаты удаляются', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Song (Remix) [Remix]',
      );
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Remix']);
    });
  });
}
