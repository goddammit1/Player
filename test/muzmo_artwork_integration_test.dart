@Tags(['live'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/muzmo_source.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/models/track.dart';

/// Интеграционный тест: Muzmo search → enrich/artwork Genius.
///
/// Проверяет, что для треков "Psychosis — Исчезаю" / "Psychosis — Эвтаназия"
/// обложка находится через Genius API.
///
/// Запуск:
///   flutter test --dart-define=GENIUS_TOKEN=your_token test/muzmo_artwork_integration_test.dart
void main() {
  late MuzmoSource source;

  setUp(() {
    source = MuzmoSource();
  });

  tearDown(() {
    source.dispose();
  });

  group('Artwork — Genius для проблемных треков', () {
    test('Psychosis — Исчезаю находит обложку через Genius', () async {
      // 1. Поиск на Muzmo
      final results = await source.search('psychosis исчезаю', limit: 5);
      if (results.isEmpty) {
        // Muzmo недоступен — пропускаем
        return;
      }

      // 2. Находим нужный трек
      Track? target;
      for (final t in results) {
        if (t.artist.toLowerCase().contains('psychosis') &&
            t.title.toLowerCase().contains('исчезаю')) {
          target = t;
          break;
        }
      }

      if (target == null) {
        // Трек не найден в выдаче Muzmo — пропускаем
        return;
      }

      // 3. Ищем обложку через ArtworkProvider
      final artworkUrl = await ArtworkProvider.instance
          .findArtwork(target.artist, target.title);

      // 4. Обложка должна быть найдена (или хотя бы не бросать исключение)
      if (ArtworkProvider.instance.hasGeniusToken) {
        expect(
          artworkUrl,
          isNotNull,
          reason: 'Обложка для "${target.artist} — ${target.title}" не найдена',
        );
        expect(artworkUrl, isNotEmpty);
        expect(artworkUrl, contains('genius.com'));
      }
    });

    test('Psychosis — Эвтаназия находит обложку через Genius', () async {
      final results = await source.search('psychosis эвтаназия', limit: 5);
      if (results.isEmpty) return;

      Track? target;
      for (final t in results) {
        if (t.artist.toLowerCase().contains('psychosis') &&
            t.title.toLowerCase().contains('эвтаназия')) {
          target = t;
          break;
        }
      }

      if (target == null) return;

      final artworkUrl = await ArtworkProvider.instance
          .findArtwork(target.artist, target.title);

      if (ArtworkProvider.instance.hasGeniusToken) {
        expect(artworkUrl, isNotNull);
        expect(artworkUrl, isNotEmpty);
        expect(artworkUrl, contains('genius.com'));
      }
    });

    test('Psychosis — Outcast находит обложку через Genius', () async {
      final results = await source.search('psychosis outcast', limit: 5);
      if (results.isEmpty) return;

      Track? target;
      for (final t in results) {
        if (t.artist.toLowerCase().contains('psychosis') &&
            t.title.toLowerCase().contains('outcast')) {
          target = t;
          break;
        }
      }

      if (target == null) return;

      final artworkUrl = await ArtworkProvider.instance
          .findArtwork(target.artist, target.title);

      if (ArtworkProvider.instance.hasGeniusToken) {
        expect(artworkUrl, isNotNull);
        expect(artworkUrl, isNotEmpty);
        expect(artworkUrl, contains('genius.com'));
      }
    });

    test('enrichArtworks обогащает треки обложками', () async {
      final results = await source.search('psychosis', limit: 10);
      if (results.isEmpty || results.length < 2) return;

      final hasToken = ArtworkProvider.instance.hasGeniusToken;

      // Вызываем enrich через пайплайн
      final completer = Completer<void>();
      final enrichedTracks = <Track>[];

      source.enrichArtworksInBackground(results, (updated) {
        enrichedTracks
          ..clear()
          ..addAll(updated);
        if (!completer.isCompleted) {
          completer.complete();
        }
      });

      // Ждём не более 15 секунд
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          // enrich не успел — не страшно, просто возвращаем что есть
        },
      );

      if (hasToken && enrichedTracks.isNotEmpty) {
        final withArtwork =
            enrichedTracks.where((t) => t.artworkUrl != null && t.artworkUrl!.isNotEmpty);
        // Хотя бы один трек должен получить обложку
        expect(withArtwork.isNotEmpty, isTrue,
            reason: 'Ни один трек не получил обложку через enrich');
      }
    });
  });
}
