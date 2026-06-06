import 'package:audio_service/audio_service.dart';

import '../../models/track.dart';

/// Определяет, имеет ли трек широкую обложку (16:9).
///
/// YouTube — широкие арты (16:9), всё остальное (Genius, Muzmo,
/// iTunes, локальные файлы) — квадратные (1:1).
///
/// Работает с [MediaItem] (из audio_service) и [Track] (модель приложения).
bool isWideArt(dynamic item) {
  String sourceId;

  if (item is Track) {
    sourceId = item.sourceId;
  } else if (item is MediaItem) {
    sourceId = item.extras?['sourceId'] as String? ?? '';
  } else {
    throw ArgumentError(
      'isWideArt принимает только Track или MediaItem, получен: ${item.runtimeType}',
    );
  }

  return sourceId == 'youtube';
}

/// Удобный геттер aspectRatio для передачи в Artwork.
///
/// ```dart
/// Artwork(
///   url: url,
///   size: 54,
///   aspectRatio: artAspectRatio(track),  // 16/9 или 1.0
/// )
/// ```
double artAspectRatio(dynamic item) => isWideArt(item) ? 16 / 9 : 1.0;