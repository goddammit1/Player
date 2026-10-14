@Tags(['unit'])
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/artwork_provider.dart';

/// Общая очередь HTTP-запросов ArtworkProvider (лимит + приоритет плеера)
/// и повтор после сетевой ошибки.
///
/// Запуск:
///   flutter test test/sources/artwork_provider_queue_test.dart
void main() {
  late ArtworkProvider provider;
  late List<Duration> savedDelays;

  Map<String, dynamic> geniusResponse(String title) => {
        'response': {
          'hits': [
            {
              'result': {
                'title': title,
                'primary_artist': {'name': 'Artist'},
                'song_art_image_url': 'https://images.genius.com/$title.png',
              },
            },
          ],
        },
      };

  setUp(() {
    provider = ArtworkProvider.instance;
    provider.clearMemCache();
    savedDelays = ArtworkProvider.networkRetryDelays;
    ArtworkProvider.networkRetryDelays = const [Duration.zero, Duration.zero];
  });

  tearDown(() {
    ArtworkProvider.networkRetryDelays = savedDelays;
    provider
      ..geniusSearchOverride = null
      ..geniusFetcherOverride = null
      ..itunesFetcherOverride = null
      ..clearMemCache();
  });

  group('повтор после сетевой ошибки', () {
    test('Genius упал по сети → повтор находит обложку', () async {
      var geniusCalls = 0;
      var itunesCalls = 0;
      provider.geniusFetcherOverride = (_, _, _) async {
        geniusCalls++;
        if (geniusCalls == 1) throw TimeoutException('connect');
        return 'https://images.genius.com/ok.png';
      };
      provider.itunesFetcherOverride = (_, _, _) async {
        itunesCalls++;
        return '';
      };

      final url = await provider.findArtwork('Artist', 'Retry Ok');

      expect(url, 'https://images.genius.com/ok.png');
      expect(geniusCalls, 2);
      expect(itunesCalls, 1, reason: 'iTunes ответил — его не повторяем');
    });

    test('«не найдено» без ошибки не повторяется', () async {
      var geniusCalls = 0;
      provider.geniusFetcherOverride = (_, _, _) async {
        geniusCalls++;
        return '';
      };
      provider.itunesFetcherOverride = (_, _, _) async => '';

      expect(await provider.findArtwork('Artist', 'Not Found'), isNull);
      expect(geniusCalls, 1);
    });

    test('число повторов ограничено networkRetryDelays', () async {
      var geniusCalls = 0;
      provider.geniusFetcherOverride = (_, _, _) async {
        geniusCalls++;
        throw TimeoutException('connect');
      };
      provider.itunesFetcherOverride = (_, _, _) async => '';

      expect(await provider.findArtwork('Artist', 'Always Down'), isNull);
      expect(geniusCalls, 1 + ArtworkProvider.networkRetryDelays.length);
    });
  });

  group('отключение iTunes после серии 403/429', () {
    var itunesCalls = 0;

    setUp(() {
      itunesCalls = 0;
      provider.resetItunesAvailability();
      provider.geniusFetcherOverride = (_, _, _) async => '';
    });

    tearDown(() {
      provider
        ..itunesSearchOverride = null
        ..resetItunesAvailability();
    });

    test('после itunesRejectThreshold отказов подряд iTunes не запрашивается',
        () async {
      provider.itunesSearchOverride = (_) async {
        itunesCalls++;
        return (403, null);
      };

      for (var i = 0; i < ArtworkProvider.itunesRejectThreshold; i++) {
        await provider.findArtwork('Artist', 'Reject$i');
      }
      expect(provider.isItunesAvailable, isFalse);

      await provider.findArtwork('Artist', 'AfterBlock');
      expect(itunesCalls, ArtworkProvider.itunesRejectThreshold);
    });

    test('успешный ответ сбрасывает счётчик отказов', () async {
      var status = 429;
      provider.itunesSearchOverride = (_) async {
        itunesCalls++;
        return (status, {'results': <Object>[]});
      };

      for (var i = 0; i < ArtworkProvider.itunesRejectThreshold - 1; i++) {
        await provider.findArtwork('Artist', 'Reject$i');
      }
      status = 200;
      await provider.findArtwork('Artist', 'Ok');
      status = 429;
      await provider.findArtwork('Artist', 'RejectAgain');

      expect(provider.isItunesAvailable, isTrue);
    });
  });

  group('очередь HTTP-запросов', () {
    // Каждый запрос к Genius висит, пока тест не откроет его «шлюз».
    late Map<String, Completer<void>> gates;
    late List<String> started;
    late int active;
    late int maxActive;

    setUp(() {
      gates = {};
      started = [];
      active = 0;
      maxActive = 0;
      provider.itunesFetcherOverride = (_, _, _) async => '';
      provider.geniusSearchOverride = (q) async {
        active++;
        maxActive = max(maxActive, active);
        started.add(q);
        final gate = gates[q] = Completer<void>();
        await gate.future;
        active--;
        return (200, geniusResponse(q.split(' ').last));
      };
    });

    /// Открывает все шлюзы, пока не завершатся все запросы.
    Future<void> drain(List<Future<Object?>> lookups) async {
      final all = Future.wait(lookups);
      var done = false;
      unawaited(all.whenComplete(() => done = true));
      while (!done) {
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await pumpEventQueue();
      }
    }

    test('одновременно идёт не больше maxConcurrentRequests', () async {
      final lookups = [
        for (var i = 0; i < 10; i++)
          provider.findArtwork('Artist', 'Song$i'),
      ];
      await pumpEventQueue();

      expect(started, hasLength(ArtworkProvider.maxConcurrentRequests));

      await drain(lookups);
      expect(maxActive, ArtworkProvider.maxConcurrentRequests);
      expect(started, hasLength(10));
    });

    test('запрос плеера проходит раньше фоновой очереди', () async {
      final lookups = <Future<Object?>>[
        for (var i = 0; i < ArtworkProvider.maxConcurrentRequests; i++)
          provider.findArtwork('Artist', 'Busy$i'),
      ];
      await pumpEventQueue();
      lookups.add(provider.findArtwork('Artist', 'Background'));
      await pumpEventQueue();
      lookups.add(ArtworkProvider.runPrioritized(
        () => provider.findArtwork('Artist', 'NowPlaying'),
      ));
      await pumpEventQueue();

      gates['artist Busy0']!.complete();
      await pumpEventQueue();

      expect(started, contains('artist NowPlaying'));
      expect(started, isNot(contains('artist Background')));

      await drain(lookups);
    });

    test('плеер поднимает в очереди уже ждущий фоновый запрос того же трека',
        () async {
      final lookups = <Future<Object?>>[
        for (var i = 0; i < ArtworkProvider.maxConcurrentRequests; i++)
          provider.findArtwork('Artist', 'Busy$i'),
      ];
      await pumpEventQueue();
      lookups
        ..add(provider.findArtwork('Artist', 'Other'))
        ..add(provider.findArtwork('Artist', 'Shared'));
      await pumpEventQueue();
      // Плеер просит тот же трек — присоединяется к фоновому запросу.
      final prio = ArtworkProvider.runPrioritized(
        () => provider.findArtwork('Artist', 'Shared'),
      );
      lookups.add(prio);
      await pumpEventQueue();

      gates['artist Busy0']!.complete();
      await pumpEventQueue();

      expect(started, contains('artist Shared'));
      expect(started, isNot(contains('artist Other')));

      await drain(lookups);
      expect(await prio, contains('images.genius.com/Shared'));
    });
  });
}
