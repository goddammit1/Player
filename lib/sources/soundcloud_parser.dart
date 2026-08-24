import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/track.dart';

/// Чистый (без сети / Dio / запросов) парсинг SoundCloud: извлечение
/// client_id из JS-бандлов главной страницы и конверсия JSON API в [Track].
///
/// Это верхний слой — сюда вынесена вся конвертация, чтобы сетевой
/// [SoundCloudSource] занимался только запросами и резолвом стримов.
abstract class SoundCloudParser {
  static final RegExp clientIdRe =
      RegExp(r'client_id\s*:\s*"([a-zA-Z0-9]{20,})"');

  static Map<String, dynamic>? asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  /// Протокол транскодинга (progressive / hls / cbc-encrypted-hls / ...).
  static String protocolOf(dynamic data) {
    final format = data is Map ? data['format'] : null;
    return (format is Map ? format['protocol'] as String? : '') ?? '';
  }

  /// Отбирает незашифрованные (не DRM) транскодинги из JSON.
  ///
  /// Игнорирует `cbc-encrypted-hls` и т.п., которые ExoPlayer не может
  /// расшифровать, и записи без URL.
  static List<Map<String, dynamic>> filterNonEncryptedTranscodings(
    Object? rawTranscodings,
  ) {
    final transcodings = <Map<String, dynamic>>[];
    if (rawTranscodings is! List) return transcodings;
    for (final t in rawTranscodings) {
      if (t is! Map) continue;
      final url = t['url'];
      if (protocolOf(t).contains('encrypted')) continue;
      if (url is String && url.isNotEmpty) {
        transcodings.add(Map<String, dynamic>.from(t));
      }
    }
    return transcodings;
  }

  static int? bitrateFromTranscoding(Map t) {
    final preset = (t['preset'] as String? ?? '').toLowerCase();
    final quality = (t['quality'] as String? ?? '').toLowerCase();
    final format = t['format'];
    final mime = format is Map
        ? (format['mime_type'] as String? ?? '').toLowerCase()
        : '';

    if (quality == 'hq') return 256;
    if (preset.startsWith('mp3') || mime.contains('mpeg')) return 128;
    if (preset.startsWith('opus') || mime.contains('opus')) return 64;
    if (preset.startsWith('aac') || mime.contains('mp4')) return 160;
    return null;
  }

  static String? bestArtwork(Map item) {
    String? raw = item['artwork_url'] as String?;
    if (raw == null || raw.isEmpty) {
      final user = item['user'];
      raw = user is Map ? user['avatar_url'] as String? : null;
    }
    if (raw == null || raw.isEmpty) return null;
    return raw.replaceAll('-large.', '-t500x500.');
  }

  static List<Track> parseTracks(String sourceId, Object? data, int limit) {
    final map = asMap(data);
    if (map == null) return const [];

    final collection = (map['collection'] as List?) ?? const [];
    final result = <Track>[];

    for (final item in collection) {
      if (item is! Map) continue;
      final kind = item['kind'];
      if (kind != null && kind != 'track') continue;

      final media = item['media'];
      final rawTranscodings = media is Map ? media['transcodings'] : null;
      if (rawTranscodings is! List || rawTranscodings.isEmpty) continue;

      final transcodings = filterNonEncryptedTranscodings(rawTranscodings);
      if (transcodings.isEmpty) continue;

      final trackAuth = item['track_authorization'] as String?;
      final idVal = item['id'];
      if (idVal == null) continue;
      final trackId = idVal.toString();

      final title = (item['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;

      final user = item['user'];
      final artist = (user is Map ? user['username'] as String? : null)
              ?.trim() ??
          'Unknown';

      final durationMs = item['duration'];
      final duration = durationMs is int
          ? Duration(milliseconds: durationMs)
          : (durationMs is num
              ? Duration(milliseconds: durationMs.toInt())
              : null);

      final artworkUrl = bestArtwork(item);
      final presetKbps = bitrateFromTranscoding(transcodings.first);

      result.add(
        Track(
          id: trackId,
          sourceId: sourceId,
          title: title,
          artist: artist,
          duration: duration,
          artworkUrl: artworkUrl,
          qualityScore: presetKbps,
          qualityLabel: presetKbps != null ? '$presetKbps kbps' : null,
          extra: {
            'transcodings': transcodings,
            if (trackAuth != null && trackAuth.isNotEmpty)
              'trackAuthorization': trackAuth,
          },
        ),
      );

      if (result.length >= limit) break;
    }

    if (kDebugMode) debugPrint('[SoundCloud] Найдено треков (без DRM): ${result.length}');

    return result;
  }
}