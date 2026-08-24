// Юнит-тест слоя конверсии lib/sources/conversion.dart (Фаза 2, 2.2–2.3).
//
// Проверяет mediaItemToTrack — конверсию MediaItem (audio_service) в Track,
// которая была вынесена из lib/ui/widgets/queue_sheet.dart, чтобы UI не
// содержал конверсии моделей данных. Детерминированный тест: без сети,
// без реального HTTP — только чистые данные.
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';

import 'package:player/sources/conversion.dart';

void main() {
  group('mediaItemToTrack', () {
    test('maps basic fields', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'muzmo_1',
        title: 'эвтаназия',
        artist: 'Psychosis, Pavshiy',
        duration: Duration(seconds: 240),
        extras: {'sourceId': 'muzmo'},
      ));
      expect(t.id, 'muzmo_1');
      expect(t.sourceId, 'muzmo');
      expect(t.title, 'эвтаназия');
      expect(t.artist, 'Psychosis, Pavshiy');
      expect(t.duration, Duration(seconds: 240));
    });

    test('falls back artist to empty string', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        extras: {'sourceId': 'youtube'},
      ));
      expect(t.artist, '');
    });

    test('prefers sourceId over source_id', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {'sourceId': 'soundcloud', 'source_id': 'youtube'},
      ));
      expect(t.sourceId, 'soundcloud');
    });

    test('falls back to source_id when sourceId missing', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {'source_id': 'muzmo'},
      ));
      expect(t.sourceId, 'muzmo');
    });

    test('defaults sourceId to local', () {
      final t = mediaItemToTrack(MediaItem(id: 'x', title: 'T'));
      expect(t.sourceId, 'local');
    });

    test('keeps quality fields and extra', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        extras: {
          'sourceId': 'youtube',
          'quality_score': 85,
          'quality_label': 'HD',
          'k': 'v',
        },
      ));
      expect(t.qualityScore, 85);
      expect(t.qualityLabel, 'HD');
      expect(t.extra['k'], 'v');
    });

    test('artworkUri maps to artworkUrl', () {
      final t = mediaItemToTrack(MediaItem(
        id: 'x',
        title: 'T',
        artist: 'A',
        artUri: Uri.parse('https://img.example.com/cover.jpg'),
        extras: {'sourceId': 'youtube'},
      ));
      expect(t.artworkUrl, contains('img.example.com'));
    });
  });
}
