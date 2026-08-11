// Тесты TTL кэша найденных URL обложек (Genius/iTunes) в ArtworkProvider.
//
// Проверяют, что:
//  - свежие URL отдаются из in-memory/SQLite кэша без сети;
//  - устаревшие (TTL истёк) лениво перезапрашиваются и подхватывают новую
//    обложку Genius (с обновлением timestamp в SQLite);
//  - при неудаче/отсутствии результата устаревший URL служит fallback и
//    TTL не обновляется;
//  - старые записи «голым URL» (без timestamp) мигрируются при чтении.
//
// Запуск:
//   flutter test test/sources/artwork_provider_ttl_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/app_database.dart';
import 'package:player/sources/artwork_provider.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  setUp(() async {
    await TestHarness.setUpDb();
    ArtworkProvider.instance.clearMemCache();
  });

  tearDown(() async {
    ArtworkProvider.instance
      ..geniusFetcherOverride = null
      ..itunesFetcherOverride = null
      ..clearMemCache();
    await TestHarness.tearDownDb();
  });

  /// Даёт завершиться fire-and-forget записям ArtworkProvider в SQLite.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  group('TTL найденных URL обложек', () {
    test('свежая in-memory запись отдаётся без единого запроса в сеть', () async {
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      ArtworkProvider.instance
          .cacheArtworkForTesting('Artist', 'Song', 'http://mem.example.com/1.jpg');

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://mem.example.com/1.jpg',
      );
    });

    test('устаревшая in-memory запись отбрасывается, URL перезапрашивается', () async {
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async =>
          'http://genius.example.com/new.jpg';
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
          null;

      ArtworkProvider.instance
          .cacheArtworkForTesting('Artist', 'Song', 'http://mem.example.com/old.jpg');
      ArtworkProvider.instance.expireArtworkForTesting('Artist', 'Song');

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://genius.example.com/new.jpg',
        reason: 'после истечения TTL должен сработать ленивый перезапрос',
      );
    });

    test('свежая запись из SQLite отдаётся без сети', () async {
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      await ArtworkProvider.instance.cacheArtworkToDbForTesting(
        'Artist',
        'Song',
        'http://db.example.com/1.jpg',
        DateTime.now(),
      );

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://db.example.com/1.jpg',
      );
    });

    test('устаревшая запись из SQLite перезапрашивается и подхватывает новый URL', () async {
      final old = DateTime.now().subtract(
        ArtworkProvider.foundUrlTtl + const Duration(days: 1),
      );
      await ArtworkProvider.instance.cacheArtworkToDbForTesting(
        'Artist',
        'Song',
        'http://db.example.com/old.jpg',
        old,
      );

      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async =>
          'http://genius.example.com/updated.jpg';
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
          null;

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://genius.example.com/updated.jpg',
        reason: 'TTL истёк — Genius перезапрошен, новая обложка подхвачена',
      );

      // Новый URL должен лечь в SQLite со свежим timestamp.
      await settle();
      final raw = await AppDatabase.instance.getSetting(
        ArtworkProvider.instance.cacheKeyForTesting('Artist', 'Song'),
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['u'], 'http://genius.example.com/updated.jpg');
      final ts = decoded['t'] as int;
      final ageSec = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(ts))
          .inSeconds
          .abs();
      expect(ageSec, lessThan(60), reason: 'timestamp должен обновиться на текущий');
    });

    test('устаревший URL служит fallback, если сеть ничего нового не нашла', () async {
      final old = DateTime.now().subtract(
        ArtworkProvider.foundUrlTtl + const Duration(days: 1),
      );
      await ArtworkProvider.instance.cacheArtworkToDbForTesting(
        'Artist',
        'Song',
        'http://db.example.com/old.jpg',
        old,
      );

      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async => '';
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
          null;

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://db.example.com/old.jpg',
        reason: 'обложка не должна пропадать из-за отсутствия результата',
      );

      // TTL не обновляется: в БД остаётся старый URL со старым timestamp,
      // чтобы следующий вызов снова перезапросил Genius.
      await settle();
      final raw = await AppDatabase.instance.getSetting(
        ArtworkProvider.instance.cacheKeyForTesting('Artist', 'Song'),
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['u'], 'http://db.example.com/old.jpg');
      expect(decoded['t'], old.millisecondsSinceEpoch);
    });

    test('старая запись «голым URL» (без timestamp) мигрируется при чтении', () async {
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      await AppDatabase.instance.setSetting(
        ArtworkProvider.instance.cacheKeyForTesting('Artist', 'Song'),
        'http://db.example.com/legacy.jpg',
      );

      expect(
        await ArtworkProvider.instance.findArtwork('Artist', 'Song'),
        'http://db.example.com/legacy.jpg',
        reason: 'записи без timestamp считаются свежими — без шторма перезапросов',
      );

      // Запись должна мигрировать в JSON-формат с timestamp.
      await settle();
      final raw = await AppDatabase.instance.getSetting(
        ArtworkProvider.instance.cacheKeyForTesting('Artist', 'Song'),
      );
      expect(raw!.startsWith('{'), isTrue, reason: 'голый URL должен мигрировать в JSON');
      expect(jsonDecode(raw)['u'], 'http://db.example.com/legacy.jpg');
    });

    test('повторные вызовы в пределах TTL не дёргают сеть', () async {
      var calls = 0;
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
        calls++;
        return 'http://genius.example.com/1.jpg';
      };
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async =>
          null;

      final first = await ArtworkProvider.instance.findArtwork('Artist', 'Song');
      final second = await ArtworkProvider.instance.findArtwork('Artist', 'Song');
      final third = await ArtworkProvider.instance.findArtwork('Artist', 'Song');

      expect(first, 'http://genius.example.com/1.jpg');
      expect(second, first);
      expect(third, first);
      expect(calls, 1, reason: 'пока запись свежая, сеть дёргается один раз');
    });

    test('isArtworkStaleAsync: свежая запись → false, устаревшая → true', () async {
      // Свежая in-memory запись.
      ArtworkProvider.instance
          .cacheArtworkForTesting('Artist', 'Fresh', 'http://mem.example.com/1.jpg');
      expect(
        await ArtworkProvider.instance.isArtworkStaleAsync('Artist', 'Fresh'),
        isFalse,
        reason: 'свежая запись в памяти — перезапрос не нужен',
      );

      // Свежая SQLite-запись (без сети).
      await ArtworkProvider.instance.cacheArtworkToDbForTesting(
        'Artist',
        'FreshDb',
        'http://db.example.com/1.jpg',
        DateTime.now(),
      );
      expect(
        await ArtworkProvider.instance.isArtworkStaleAsync('Artist', 'FreshDb'),
        isFalse,
        reason: 'свежая запись в БД — перезапрос не нужен',
      );

      // Устаревшая SQLite-запись.
      final old = DateTime.now().subtract(
        ArtworkProvider.foundUrlTtl + const Duration(days: 1),
      );
      await ArtworkProvider.instance.cacheArtworkToDbForTesting(
        'Artist',
        'StaleDb',
        'http://db.example.com/old.jpg',
        old,
      );
      // Сеть НЕ должна вызываться внутри isArtworkStaleAsync.
      ArtworkProvider.instance.geniusFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      ArtworkProvider.instance.itunesFetcherOverride = (_, _, _) async {
        throw StateError('network must not be called');
      };
      expect(
        await ArtworkProvider.instance.isArtworkStaleAsync('Artist', 'StaleDb'),
        isTrue,
        reason: 'устаревшая запись — нужен перезапрос',
      );

      // Отсутствует запись вообще → stale.
      expect(
        await ArtworkProvider.instance.isArtworkStaleAsync('Artist', 'NoEntry'),
        isTrue,
        reason: 'нет записи — нужно искать',
      );
    });
  });
}
