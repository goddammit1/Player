// lib/core/player_conversions.dart

import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;

import '../models/track.dart';
import 'artwork_helper.dart';
import 'database/track_row_codec.dart';

/// Чистые конверсии сущностей плеера: `Track` -> `MediaItem` и `Track` -> row
/// для сохранения сессии.
///
/// Выделено из монолита `PlayerService` в рамках декомпозиции по
/// обязанностям (Фаза 1, шаг 1.2). Не содержит состояния плеера и не знает
/// об audio-движке — это делает модуль переиспользуемым и тестируемым
/// отдельно от логики воспроизведения.
abstract class PlayerConversions {
  /// Конвертирует [Track] в [MediaItem] для UI-плеера.
  ///
  /// Учитывает кастомную обложку: если для трека задан локальный путь через
  /// [ArtworkHelper.getCustomArtworkSync] — он имеет приоритет над URL из
  /// источника ([Track.artworkUrl]).
  static MediaItem toMediaItem(Track t) {
    final customArt = ArtworkHelper.getCustomArtworkSync(t.id);
    final artUri = customArt != null
        ? Uri.file(customArt)
        : (t.artworkUrl != null ? Uri.parse(t.artworkUrl!) : null);

    return MediaItem(
      id: t.globalId,
      title: t.title,
      artist: t.artist,
      duration: t.duration,
      artUri: artUri,
      extras: {
        'sourceId': t.sourceId,
        'trackId': t.id,
        'originalArtworkUrl': t.artworkUrl,
        'qualityLabel': t.qualityLabel,
      },
    );
  }

  /// Сериализует [track] в Map, совместимый с таблицей `playback_state`
  /// в SQLite (тот же формат, что использует `AppDatabase`).
  static Map<String, dynamic> trackToRow(Track track) {
    return {
      'track_id': track.id,
      'source_id': track.sourceId,
      'title': track.title,
      'artist': track.artist,
      'duration_ms': track.duration?.inMilliseconds,
      'artwork_url': track.artworkUrl,
      'quality_score': track.qualityScore,
      'quality_label': track.qualityLabel,
      'track_global_id': track.globalId,
      'extra_json': jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
    };
  }
}