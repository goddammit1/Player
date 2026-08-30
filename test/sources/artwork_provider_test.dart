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

    test('Original Mix — теперь ХИНТ (всё в скобках = хинт)', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Track (Original Mix)');
      expect(r.cleanTitle, 'Track');
      expect(r.versionHints, ['Original Mix']);
    });

    test('Album Version — теперь ХИНТ (всё в скобках = хинт)', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Album Version)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Album Version']);
    });

    test('Radio Edit — хинт (версия)', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Radio Edit)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, ['Radio Edit']);
    });

    test('Explicit/Clean — шум (рейтинг цензуры)', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Song (Explicit)');
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, isEmpty);

      final r2 = ArtworkProvider.extractVersionHintsForTest('Song [Clean]');
      expect(r2.cleanTitle, 'Song');
      expect(r2.versionHints, isEmpty);
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

  group('_normalize (unicode: кириллица сохраняется)', () {
    test('кириллическое название не вырезается', () {
      expect(ArtworkProvider.normalizeForTest('Исчезаю'), 'исчезаю');
      expect(
        ArtworkProvider.normalizeForTest('Psychosis — Исчезаю'),
        'psychosis исчезаю',
      );
    });

    test('ASCII-поведение не меняется', () {
      expect(
        ArtworkProvider.normalizeForTest('Believer (Remix)'),
        'believer remix',
      );
      expect(ArtworkProvider.normalizeForTest('Song*'), 'song');
    });
  });

  group('titleMatches (версионные хинты)', () {
    test('точное равенство — матч', () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer (Remix)',
          'believer remix',
          hasVersionHints: true,
        ),
        isTrue,
      );
    });

    test('искали версию, а у Genius только оригинал — НЕ матч', () {
      // Раньше "believer remix".contains("believer") возвращал true и обложка
      // оригинала/альбома подставлялась в трек-версию.
      expect(
        ArtworkProvider.titleMatches(
          'Believer',
          'believer remix',
          hasVersionHints: true,
        ),
        isFalse,
      );
    });

    test('без хинтов обратный contains по-прежнему разрешён', () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer',
          'believer remix',
          hasVersionHints: false,
        ),
        isTrue,
      );
    });

    test('другая версия — не матч', () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer (Live)',
          'believer remix',
          hasVersionHints: true,
        ),
        isFalse,
      );
    });

    test('страница содержит искомую версию целиком — матч', () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer (Remix) [feat. X]',
          'believer remix',
          hasVersionHints: true,
        ),
        isTrue,
      );
    });

    test('пустой want — матч по умолчанию', () {
      expect(
        ArtworkProvider.titleMatches('Anything', '', hasVersionHints: true),
        isTrue,
      );
    });

    test('кириллица: точное совпадение', () {
      expect(
        ArtworkProvider.titleMatches(
          'Исчезаю',
          'исчезаю',
          hasVersionHints: false,
        ),
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------------
  //  §7.1. Классификация скобок: версия vs часть названия
  // ------------------------------------------------------------------
  group('extractVersionHints / классификация скобок', () {
    test('(Sic) — весь заголовок в скобках → titleParts', () {
      final r = ArtworkProvider.extractVersionHintsForTest('(Sic)');
      expect(r.cleanTitle, '(Sic)'); // cleanSearchTerm fallback на исходник
      expect(r.versionHints, isEmpty);
      expect(r.titleParts, ['Sic']);
    });

    test("(Don't Fear) The Reaper → titleParts", () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        "(Don't Fear) The Reaper",
      );
      expect(r.cleanTitle, 'The Reaper');
      expect(r.versionHints, isEmpty);
      expect(r.titleParts, ["Don't Fear"]);
    });

    test('(Reach Up for The) Sunrise → titleParts', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        '(Reach Up for The) Sunrise',
      );
      expect(r.cleanTitle, 'Sunrise');
      expect(r.titleParts, ['Reach Up for The']);
    });

    test('Believer (Remix) → версия, НЕ название (регрессия)', () {
      final r = ArtworkProvider.extractVersionHintsForTest('Believer (Remix)');
      expect(r.cleanTitle, 'Believer');
      expect(r.versionHints, ['Remix']);
      expect(r.titleParts, isEmpty);
    });

    test('Song (2001 Remaster) → год + keyword = версия', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Song (2001 Remaster)',
      );
      expect(r.versionHints, ['2001 Remaster']);
      expect(r.titleParts, isEmpty);
    });

    test('Song (Official Video) → шум', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Song (Official Video)',
      );
      expect(r.cleanTitle, 'Song');
      expect(r.versionHints, isEmpty);
      expect(r.titleParts, isEmpty);
    });

    test('Song [Live] (Acoustic) → обе версии в hints', () {
      final r = ArtworkProvider.extractVersionHintsForTest(
        'Song [Live] (Acoustic)',
      );
      // Порядок зависит от порядка regex (круглые скобки первыми) —
      // проверяем множество, а не последовательность.
      expect(r.versionHints.toSet(), {'Live', 'Acoustic'});
      expect(r.titleParts, isEmpty);
    });

    test('(Sic) (Remix) → часть названия + версия', () {
      final r = ArtworkProvider.extractVersionHintsForTest('(Sic) (Remix)');
      expect(r.titleParts, ['Sic']);
      expect(r.versionHints, ['Remix']);
    });
  });

  // ------------------------------------------------------------------
  //  §7.2. buildGeniusQueryVariants
  // ------------------------------------------------------------------
  group('buildGeniusQueryVariants', () {
    test('slipknot (sic) → slipknot sic, без дублей и пустых', () {
      // cleanTitle='' — весь тайтл был в скобках (effectiveCleanTitle
      // в _fetchGenius после удаления скобок пуст).
      final variants = ArtworkProvider.buildGeniusQueryVariantsForTest(
        artists: ['slipknot'],
        originalTitle: '(Sic)',
        cleanTitle: '',
        versionHints: [],
        titleParts: ['Sic'],
      );
      // Варианты №2 и №3 дедуплицируются к «slipknot Sic».
      expect(variants, ['slipknot Sic']);
      expect(
        variants.any((v) => v.trim() == 'slipknot'),
        isFalse,
        reason: 'нет варианта только из артиста',
      );
      expect(variants.first.toLowerCase(), contains('sic'));
      expect(variants.first, isNot(contains('(')));
    });

    test("(Don't Fear) The Reaper → вариант с don't fear", () {
      final variants = ArtworkProvider.buildGeniusQueryVariantsForTest(
        artists: ['blue öyster cult'],
        originalTitle: "(Don't Fear) The Reaper",
        cleanTitle: 'The Reaper',
        versionHints: [],
        titleParts: ["Don't Fear"],
      );
      expect(variants.first.toLowerCase(), contains('the reaper'));
      expect(
        variants.any(
          (v) => v.toLowerCase().contains("don't fear the reaper"),
        ),
        isTrue,
      );
    });

    test('Song (Remix) → вариант с remix первым, вариант без remix есть', () {
      final variants = ArtworkProvider.buildGeniusQueryVariantsForTest(
        artists: ['artist'],
        originalTitle: 'Song (Remix)',
        cleanTitle: 'Song',
        versionHints: ['Remix'],
        titleParts: [],
      );
      expect(variants.first, 'artist Song Remix');
      expect(variants, contains('artist Song'));
    });

    test('дедупликация: идентичные варианты схлопываются', () {
      final variants = ArtworkProvider.buildGeniusQueryVariantsForTest(
        artists: ['a'],
        originalTitle: 'Song',
        cleanTitle: 'Song',
        versionHints: [],
        titleParts: [],
      );
      expect(variants, ['a Song']);
    });

    test('лимит: не более 4 уникальных вариантов', () {
      final variants = ArtworkProvider.buildGeniusQueryVariantsForTest(
        artists: ['a'],
        originalTitle: '(Part) Song [Live]',
        cleanTitle: 'Song',
        versionHints: ['Live'],
        titleParts: ['Part'],
      );
      expect(variants.length, lessThanOrEqualTo(4));
    });
  });

  // ------------------------------------------------------------------
  //  §7.3. titleMatches с cleanTitleEmpty
  // ------------------------------------------------------------------
  group('titleMatches (cleanTitleEmpty)', () {
    test('(Sic) vs sic → true', () {
      expect(
        ArtworkProvider.titleMatches(
          '(Sic)',
          'sic',
          hasVersionHints: true,
          cleanTitleEmpty: true,
        ),
        isTrue,
      );
    });

    test('Sic vs sic → true (exact)', () {
      expect(
        ArtworkProvider.titleMatches(
          'Sic',
          'sic',
          hasVersionHints: true,
          cleanTitleEmpty: true,
        ),
        isTrue,
      );
    });

    test('(Sic) [Live] vs sic → true', () {
      expect(
        ArtworkProvider.titleMatches(
          '(Sic) [Live]',
          'sic',
          hasVersionHints: true,
          cleanTitleEmpty: true,
        ),
        isTrue,
      );
    });

    test('регрессия: Believer vs believer remix, cleanTitleEmpty=false → false',
        () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer',
          'believer remix',
          hasVersionHints: true,
          cleanTitleEmpty: false,
        ),
        isFalse,
      );
    });

    test('регрессия: Believer (Remix) [feat. X] → true (как сейчас)', () {
      expect(
        ArtworkProvider.titleMatches(
          'Believer (Remix) [feat. X]',
          'believer remix',
          hasVersionHints: true,
        ),
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------------
  //  §7.4. Интеграция _fetchGenius: порядок retry, дедуп, 401-стоп
  // ------------------------------------------------------------------
  group('_fetchGenius (интеграция, офлайн)', () {
    late ArtworkProvider provider;

    Map<String, dynamic> geniusHit({
      required String title,
      required String artistName,
      String art = 'https://images.genius.com/art.png',
    }) {
      return {
        'result': {
          'title': title,
          'primary_artist': {'name': artistName},
          'song_art_image_url': art,
        },
      };
    }

    Map<String, dynamic> geniusResponse(List<Map<String, dynamic>> hits) {
      return {
        'response': {'hits': hits},
      };
    }

    setUp(() {
      provider = ArtworkProvider.instance;
      provider.clearMemCache();
      provider.itunesFetcherOverride =
          (artist, title, preferredSize) async => '';
    });

    tearDown(() {
      provider.geniusSearchOverride = null;
      provider.geniusFetcherOverride = null;
      provider.itunesFetcherOverride = null;
      provider.clearMemCache();
    });

    test('(Sic): запрос "slipknot sic" матчит страницу "(Sic)"', () async {
      final calls = <String>[];
      provider.geniusSearchOverride = (q) async {
        calls.add(q);
        return (
          200,
          geniusResponse([
            geniusHit(title: '(Sic)', artistName: 'Slipknot'),
          ]),
        );
      };

      final url = await provider.findArtwork('Slipknot', '(Sic)');
      expect(url, isNotNull);
      expect(url, contains('images.genius.com'));
      expect(calls, isNotEmpty);
      // Содержимое скобок-названия попало в запрос без скобок
      expect(calls.first.toLowerCase(), contains('sic'));
      expect(calls.first, isNot(contains('(')));
    });

    test('retry: первый вариант 0 hits → второй даёт результат', () async {
      final calls = <String>[];
      provider.geniusSearchOverride = (q) async {
        calls.add(q);
        // Первый вариант (с hints) — пусто, второй (без hints) — hits
        // со страницей ВЕРСИИ (strict-матчинг отклоняет страницу оригинала
        // «Song» для «Song (Remix)» — это by design, см. §4.1 плана).
        if (q.contains('Remix')) {
          return (200, geniusResponse(const []));
        }
        return (
          200,
          geniusResponse([
            geniusHit(title: 'Song (Remix)', artistName: 'Artist'),
          ]),
        );
      };

      final url = await provider.findArtwork('Artist', 'Song (Remix)');
      expect(url, isNotNull);
      expect(calls.length, greaterThanOrEqualTo(2));
      // Порядок: с хинтами первым.
      expect(calls.first.toLowerCase(), contains('remix'));
    });

    test('дедупликация: одинаковый q не порождает повторный вызов', () async {
      final calls = <String>[];
      provider.geniusSearchOverride = (q) async {
        calls.add(q);
        return (
          200,
          geniusResponse([
            geniusHit(title: 'Song', artistName: 'Artist'),
          ]),
        );
      };

      await provider.findArtwork('Artist', 'Song');
      // Один вариант «artist Song» → ровно один HTTP-вызов (артист в lower,
      // тайтл сохраняет регистр cleanTitle).
      expect(calls, ['artist Song']);
    });

    test('401 → стоп: повторных вызовов нет, возвращается null', () async {
      final calls = <String>[];
      provider.geniusSearchOverride = (q) async {
        calls.add(q);
        return (401, null);
      };

      final url = await provider.findArtwork('Artist', 'Song (Remix)');
      expect(url, isNull);
      expect(calls.length, 1, reason: 'после 401 retry не выполняется');
    });
  });
}
