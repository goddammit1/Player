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
  String? artworkUrl;

  if (item is Track) {
    sourceId = item.sourceId;
    artworkUrl = item.artworkUrl;
  } else if (item is MediaItem) {
    sourceId = item.extras?['sourceId'] as String? ?? '';
    artworkUrl = item.artUri?.toString();
  } else {
    throw ArgumentError(
      'isWideArt принимает только Track или MediaItem, получен: ${item.runtimeType}',
    );
  }

  // YouTube-источник всегда 16:9. Для треков, у которых sourceId неизвестен
  // (например, восстановленных из старого кэша), определяем по URL.
  if (sourceId == 'youtube') return true;
  return isWideArtUrl(artworkUrl);
}

/// Определяет широкую обложку по URL.
///
/// YouTube-арт (ytimg.com, youtube.com, googlevideo.com) — 16:9,
/// всё остальное (Genius, iTunes, SoundCloud) — 1:1.
bool isWideArtUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final lower = url.toLowerCase();
  return lower.contains('ytimg.com') ||
      lower.contains('youtube.com') ||
      lower.contains('googlevideo.com');
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

/// Возвращает aspect ratio для URL обложки.
///
/// Обёртка над [isWideArtUrl], используется там, где нет Track/MediaItem.
double urlAspectRatio(String? url) => isWideArtUrl(url) ? 16 / 9 : 1.0;
