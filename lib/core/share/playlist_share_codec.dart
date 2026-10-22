import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import '../../models/playlist.dart';
import '../../models/track.dart';

/// Формат плейлиста для ссылок «Share link» (сервер `share-server/`).
///
/// Отдельный от [PlaylistBackup]: бэкап хранит плейлист как есть, а здесь
/// уходит только то, что имеет смысл у получателя. Чего нет в JSON,
/// [Playlist.fromJson] заполняет сам (`null` / `{}`), так что ни БД, ни
/// формат бэкапа не меняются.
///
/// ```json
/// {
///   "format": "player_playlist_share",
///   "version": 1,
///   "playlist": { "name": "...", "tracks": [ { "id", "source_id", "title", "artist", ... } ] }
/// }
/// ```
///
/// По сети идёт gzip этого JSON. Валидация на сервере —
/// `share-server/src/validate.ts`, держать форматы в синхроне.
class PlaylistShareCodec {
  PlaylistShareCodec._();

  static const String formatTag = 'player_playlist_share';
  static const int formatVersion = 1;

  /// Ключи `Track.extra`, которые не отправляем: локальное состояние
  /// (Soulseek `cacheKey` пересчитывается из peer+filename+size) или
  /// быстро устаревающие данные о пире.
  static const Set<String> droppedExtraKeys = {
    'cacheKey',
    'queueLength',
    'uploadSpeed',
    'hasFreeUploadSlot',
  };

  /// JSON-представление для отправки. Ручной порядок сразу применяется к
  /// трекам; локальная обложка плейлиста, id и дата создания не уходят.
  static Map<String, dynamic> toShareJson(Playlist playlist) => {
    'format': formatTag,
    'version': formatVersion,
    'playlist': {
      'name': playlist.name.trim(),
      'tracks': playlist.applyManualOrder().map(_trackToJson).toList(),
    },
  };

  /// gzip(JSON) — тело `POST /api/p`.
  static Uint8List encode(Playlist playlist) => Uint8List.fromList(
    gzip.encode(utf8.encode(jsonEncode(toShareJson(playlist)))),
  );

  /// Разбирает ответ `GET /api/p/:id` (gzip JSON) в плейлист.
  ///
  /// `id` и `createdAt` у результата временные — [PlaylistRepository]
  /// при импорте всё равно назначает новые. Бросает [FormatException],
  /// если данные битые или это не наш формат.
  static Playlist decode(List<int> bytes) {
    final dynamic parsed;
    try {
      parsed = jsonDecode(utf8.decode(gzip.decode(bytes)));
    } catch (_) {
      throw const FormatException('Shared playlist data is corrupted');
    }
    if (parsed is! Map || parsed['format'] != formatTag) {
      throw const FormatException('This link does not point to a playlist');
    }
    final version = parsed['version'];
    if (version is! int || version < 1 || version > formatVersion) {
      throw const FormatException(
        'This playlist was shared from a newer version of the app — update to open it',
      );
    }
    final playlist = parsed['playlist'];
    if (playlist is! Map ||
        playlist['name'] is! String ||
        playlist['tracks'] is! List) {
      throw const FormatException('Shared playlist data is corrupted');
    }

    try {
      return Playlist.fromJson({
        'id': 'shared',
        'name': playlist['name'],
        'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        'tracks': playlist['tracks'],
      });
    } catch (_) {
      throw const FormatException('Shared playlist data is corrupted');
    }
  }

  static Map<String, dynamic> _trackToJson(Track t) {
    final artwork = t.artworkUrl;
    final extra = <String, dynamic>{
      for (final e in t.extra.entries)
        if (!droppedExtraKeys.contains(e.key) && _isJsonValue(e.value))
          e.key: e.value,
    };
    return {
      'id': t.id,
      'source_id': t.sourceId,
      'title': t.title,
      'artist': t.artist,
      'duration_ms': ?t.duration?.inMilliseconds,
      // Локальные пути (кастомные обложки) у получателя не существуют.
      if (artwork != null && _isHttpUrl(artwork)) 'artwork_url': artwork,
      'quality_score': ?t.qualityScore,
      'quality_label': ?t.qualityLabel,
      if (extra.isNotEmpty) 'extra': extra,
    };
  }

  static bool _isHttpUrl(String s) {
    final lower = s.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://');
  }

  /// Только то, что переживёт jsonEncode и пройдёт валидацию сервера.
  static bool _isJsonValue(Object? v) {
    if (v == null || v is bool || v is String) return true;
    if (v is num) return v.isFinite;
    if (v is List) return v.every(_isJsonValue);
    if (v is Map) {
      return v.keys.every((k) => k is String) && v.values.every(_isJsonValue);
    }
    return false;
  }
}
