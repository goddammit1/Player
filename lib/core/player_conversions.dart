// lib/core/player_conversions.dart

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
  /// Ключи качества, прокидываемые в [MediaItem.extras] из [Track] /
  /// [Track.extra] (QUALITY-01: данные качества не должны теряться при
  /// деградации Track → MediaItem → Track).
  ///
  /// Значения null не записываются — extras остаются компактными, а
  /// читатели ([PlayerConversions.trackFromExtras] / `mediaItemToTrack`)
  /// читают их как nullable.
  static const List<String> _extraQualityKeys = [
    'bitrate',
    'sampleRate',
    'bitDepth',
    'extension',
    'cacheKey',
    'peerUsername',
    'remoteFilename',
    'sizeBytes',
    'durationSeconds',
  ];

  /// Конвертирует [Track] в [MediaItem] для UI-плеера.
  ///
  /// Учитывает кастомную обложку: если для трека задан локальный путь через
  /// [ArtworkHelper.getCustomArtworkSync] — он имеет приоритет над URL из
  /// источника ([Track.artworkUrl]).
  ///
  /// QUALITY-01: помимо базовых полей кладёт в `extras` качество
  /// (`quality_score`/`quality_label` + атрибуты из `extra`) — чтобы
  /// пересборка Track из MediaItem ([trackFromExtras]) восстанавливала
  /// качество без сетевых вызовов (детали трека, кэш-статус Soulseek).
  static MediaItem toMediaItem(Track t) {
    final customArt = ArtworkHelper.getCustomArtworkSync(t.id);
    final artUri = customArt != null
        ? Uri.file(customArt)
        : (t.artworkUrl != null ? Uri.parse(t.artworkUrl!) : null);

    final extras = <String, dynamic>{
      'sourceId': t.sourceId,
      'trackId': t.id,
      'originalArtworkUrl': t.artworkUrl,
      'qualityLabel': t.qualityLabel,
      if (t.qualityLabel != null) 'quality_label': t.qualityLabel,
      if (t.qualityScore != null) 'quality_score': t.qualityScore,
    };
    for (final key in _extraQualityKeys) {
      final v = t.extra[key];
      if (v != null && !extras.containsKey(key)) extras[key] = v;
    }

    return MediaItem(
      id: t.globalId,
      title: t.title,
      artist: t.artist,
      duration: t.duration,
      artUri: artUri,
      extras: extras,
    );
  }

  /// Восстанавливает [Track] из [MediaItem], построенного
  /// [toMediaItem] — включая качество и данные `extra`.
  ///
  /// QUALITY-01 (данные, без UI): раньше Track, пересобранный из MediaItem
  /// в плеере, терял `extra` и `qualityScore` → детали трека показывали
  /// «unavailable», кэш-статус Soulseek был недоступен. Теперь всё
  /// качество доезжает через extras.
  ///
  /// Совместим с MediaItem без extras: поля качества/extra остаются
  /// null/пустыми.
  static Track trackFromExtras(MediaItem m) {
    final extra = m.extras ?? const <String, dynamic>{};
    return Track(
      // Чистый id трека в источнике; `m.id` — полный globalId.
      id: extra['trackId'] as String? ?? m.id,
      sourceId:
          (extra['sourceId'] as String?) ?? (extra['source_id'] as String?) ?? '',
      title: m.title,
      artist: m.artist ?? '',
      duration: m.duration,
      artworkUrl:
          extra['originalArtworkUrl'] as String? ?? m.artUri?.toString(),
      qualityScore: _intOrNull(extra['quality_score']),
      qualityLabel: (extra['qualityLabel'] as String?) ??
          (extra['quality_label'] as String?),
      // extra-атрибуты (bitrate/cacheKey/…) уже лежат в extras — Track
      // получает их как extra без отдельного копирования.
      extra: extra,
    );
  }

  static int? _intOrNull(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  /// Сериализует [track] в Map, совместимый с таблицей `playback_state`
  /// в SQLite (единый контракт [Track.toMap]/[Track.fromMap]).
  ///
  /// SESSION-01: раньше мобильный писатель клал в `queue_json` ключи
  /// `track_id`/`extra_json`, а читатель `Track.fromMap` ждал `id`/`extra`
  /// → `null as String` → restore сессии падал целиком. Теперь writer
  /// пишет формат `toMap()` (как и desktop-писатель), а legacy-записи
  /// читаются через fallback-ключи в `Track.fromMap`.
  ///
  /// `extra` проходит через [TrackRowCodec.extraPrimitives] перед
  /// `jsonEncode` (JSON-безопасность вложенных значений).
  static Map<String, dynamic> trackToRow(Track track) {
    return {
      'id': track.id,
      'source_id': track.sourceId,
      'title': track.title,
      'artist': track.artist,
      'duration_ms': track.duration?.inMilliseconds,
      'artwork_url': track.artworkUrl,
      'quality_score': track.qualityScore,
      'quality_label': track.qualityLabel,
      'extra': TrackRowCodec.extraPrimitives(track.extra),
    };
  }
}