@Tags(['unit'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_artwork_query.dart';

/// Очистка artist/title Soulseek-трека для поиска обложки. Имена файлов —
/// из реальной выдачи (замер 2026-10-14), где сырые названия не находились
/// на Genius.
///
/// Запуск:
///   flutter test test/sources/soulseek_artwork_query_test.dart
void main() {
  ({String artist, String title}) q(
    String path, {
    String fallbackArtist = 'FallbackArtist',
    String fallbackTitle = 'FallbackTitle',
  }) =>
      soulseekArtworkQuery(
        path,
        fallbackArtist: fallbackArtist,
        fallbackTitle: fallbackTitle,
      );

  void expectQuery(String path, String artist, String title) {
    final r = q(path);
    expect((r.artist, r.title), (artist, title), reason: path);
  }

  group('альбом и номер трека в имени файла', () {
    test('Artist - Album - NN - Title', () {
      expectQuery(
        r'@@x\Music\Rihanna - Good Girl Gone Bad - 04 - Breakin’ Dishes.flac',
        'Rihanna',
        'Breakin’ Dishes',
      );
      expectQuery(
        r'@@x\La Dame\Meryl - La Dame - 03 - Paparazzi.mp3',
        'Meryl',
        'Paparazzi',
      );
    });

    test('Artist - Artist - Title', () {
      expectQuery(
        '@@x/Rihanna - Rihanna - Breakin\' Dishes.mp3',
        'Rihanna',
        'Breakin\' Dishes',
      );
    });

    test('подчёркивания как разделители сегментов', () {
      expectQuery(
        '@@x/Remixes/Rihanna_Good Girl Gone Bad - The Remixes_06_'
            'Breakin’ Dishes (Soul Seekerz remix).mp3',
        'Rihanna',
        'Breakin’ Dishes (Soul Seekerz remix)',
      );
    });

    test('имя без пробелов: 04-rihanna-breakin_dishes', () {
      expectQuery(
        '@@x/FULL ALBUMS/04-rihanna-breakin_dishes.mp3',
        'rihanna',
        'breakin dishes',
      );
    });

    test('теги качества и год убираются', () {
      expectQuery(
        '@@x/Rihanna - Breakin\' Dishes [CD][FLAC][16bit][44.1kHz].flac',
        'Rihanna',
        'Breakin\' Dishes',
      );
      expectQuery(
        '@@x/Lady Gaga/Lady Gaga - (2009) [FLAC] - Paparazzi.flac',
        'Lady Gaga',
        'Paparazzi',
      );
    });
  });

  group('номер трека в начале названия, исполнитель из каталогов', () {
    test('disc-track «2-03 Title» в Artist/Album/', () {
      expectQuery(
        r'@@x\Lady Gaga\The Fame Monster\2-03 Paparazzi.flac',
        'Lady Gaga',
        'Paparazzi',
      );
    });

    test('«10. TITLE», «11.24 Title», «03 Title»', () {
      expectQuery(
        '@@x/Girls\' Generation/The Boys/10. PAPARAZZI.mp3',
        'Girls\' Generation',
        'PAPARAZZI',
      );
      expectQuery(
        '@@x/Lady Gaga/Hits/11.24 Paparazzi.mp3',
        'Lady Gaga',
        'Paparazzi',
      );
      expectQuery(
        '@@x/Lady Gaga/The Fame/03 Paparazzi.mp3',
        'Lady Gaga',
        'Paparazzi',
      );
    });

    test('каталог диска (CD1) пропускается', () {
      expectQuery(
        '@@x/Lady Gaga/The Fame Monster/CD2/03 Paparazzi.flac',
        'Lady Gaga',
        'Paparazzi',
      );
    });

    test('корень шары и свалки выше — исполнитель = ближайший каталог', () {
      expectQuery(
        r'@@abcde\Downloads\Rihanna\03 Paparazzi.mp3',
        'Rihanna',
        'Paparazzi',
      );
      expectQuery(r'@@abcde\Rihanna\03 Paparazzi.mp3', 'Rihanna', 'Paparazzi');
      expectQuery(r'C:\music\03 Paparazzi.mp3', 'FallbackArtist', 'Paparazzi');
    });

    test('каталог «Artist - Album (year)»', () {
      expectQuery(
        '@@x/music/Lady Gaga - The Fame (2008) [FLAC]/04. Paparazzi.flac',
        'Lady Gaga',
        'Paparazzi',
      );
    });

    test('папки-свалки не считаются исполнителем', () {
      expectQuery(
        '@@x/Rihanna/music/10. Breakin\' Dishes.mp3',
        'Rihanna',
        'Breakin\' Dishes',
      );
      // «music - 10. Title»: первый сегмент — свалка, берём каталоги.
      expectQuery(
        '@@x/Rihanna/Good Girl Gone Bad/music - 10. Breakin\' Dishes.mp3',
        'Rihanna',
        'Breakin\' Dishes',
      );
    });
  });

  group('не ломает обычные названия', () {
    test('простое Artist - Title', () {
      expectQuery('Artist - Title.flac', 'Artist', 'Title');
    });

    test('число как часть названия сохраняется', () {
      expectQuery('@@x/Ariana Grande/thank u, next/7 rings.mp3',
          'Ariana Grande', '7 rings');
      expectQuery('@@x/Green Day - 21 Guns.mp3', 'Green Day', '21 Guns');
    });

    test('дефис внутри слова без пробелов не режется', () {
      final r = q('@@x/Jay-Z.mp3');
      expect(r.title, 'Jay-Z');
    });

    test('ремикс в скобках остаётся в названии', () {
      expectQuery(
        '@@x/Halsey - Without Me (Illenium Remix).mp3',
        'Halsey',
        'Without Me (Illenium Remix)',
      );
    });

    test('ничего не извлечь — fallback', () {
      final r = q('@@x/04.mp3');
      expect((r.artist, r.title), ('FallbackArtist', 'FallbackTitle'));
    });
  });
}
