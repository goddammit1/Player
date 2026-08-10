import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/youtube_cache.dart';
import '../models/track.dart';
import 'artwork_provider.dart';
import 'offline_audio_source.dart' as offline;
import 'track_source.dart';

class SoundCloudSource implements TrackSource {
  static const String _siteUrl = 'https://soundcloud.com';
  static const String _apiBase = 'https://api-v2.soundcloud.com';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: true,
      headers: {
        'User-Agent': _userAgent,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9,ru;q=0.8',
      },
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  String? _clientId;
  Future<String?>? _clientIdFuture;
  int _clientIdFailedAttempts = 0;
  static const int _maxClientIdAttempts = 3;

  @override
  String get id => 'soundcloud';

  @override
  String get displayName => 'SoundCloud';

  // ═══════════════════════════════════════════════════════════════════
  //  CLIENT_ID
  // ═══════════════════════════════════════════════════════════════════

  Future<String?> _ensureClientId() {
    if (_clientId != null) return Future.value(_clientId);

    if (_clientIdFuture == null ||
        (_clientIdFailedAttempts > 0 &&
            _clientIdFailedAttempts < _maxClientIdAttempts)) {
      _clientIdFuture = _fetchClientIdWithRetry();
    }
    return _clientIdFuture!;
  }

  Future<String?> _fetchClientIdWithRetry() async {
    while (_clientIdFailedAttempts < _maxClientIdAttempts) {
      final result = await _fetchClientId();
      if (result != null && result.isNotEmpty) {
        _clientIdFailedAttempts = 0;
        _clientId = result;
        return result;
      }
      _clientIdFailedAttempts++;
      if (_clientIdFailedAttempts >= _maxClientIdAttempts) break;
      await Future.delayed(
        Duration(milliseconds: 300 * _clientIdFailedAttempts),
      );
    }
    return null;
  }

  Future<String?> _fetchClientId() async {
    try {
      if (kDebugMode) debugPrint('[SoundCloud] Парсим главную страницу для поиска client_id...');
      final pageResp = await _dio.get<String>(
        _siteUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final html = pageResp.data;
      if (html == null || html.isEmpty) return null;

      final scriptUrls = RegExp(
        r'<script[^>]+src="(https://[^"]+\.js)"',
        caseSensitive: false,
      ).allMatches(html).map((m) => m.group(1)!).toList();

      for (final url in scriptUrls.reversed) {
        final id = await _extractClientIdFromScript(url);
        if (id != null) {
          _clientId = id;
          if (kDebugMode) {
            debugPrint('[SoundCloud] Успешно извлечен client_id: ${id.substring(0, 6)}...');
          }
          return id;
        }
      }

      if (kDebugMode) debugPrint('[SoundCloud] Ошибка: Не удалось найти client_id в JS-бандлах');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[SoundCloud] Исключение при получении client_id: $e');
      return null;
    }
  }

  static final RegExp _clientIdRe =
      RegExp(r'client_id\s*:\s*"([a-zA-Z0-9]{20,})"');

  Future<String?> _extractClientIdFromScript(String scriptUrl) async {
    try {
      final resp = await _dio.get<String>(
        scriptUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final js = resp.data;
      if (js == null || js.isEmpty) return null;
      final m = _clientIdRe.firstMatch(js);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  void _invalidateClientId() {
    if (kDebugMode) debugPrint('[SoundCloud] Инвалидация client_id');
    _clientId = null;
    _clientIdFuture = null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ПОИСК
  // ═══════════════════════════════════════════════════════════════════

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    if (kDebugMode) debugPrint('[SoundCloud] Поиск: "$q" (limit: $limit)');

    final clientId = await _ensureClientId();
    if (clientId == null) return const [];

    final resp = await _dio.get<dynamic>(
      '$_apiBase/search/tracks',
      queryParameters: {
        'q': q,
        'client_id': clientId,
        'limit': limit,
      },
    );

    if (resp.statusCode == 401) {
      _invalidateClientId();
      final fresh = await _ensureClientId();
      if (fresh == null) return const [];
      return _searchWith(fresh, q, limit);
    }

    if (resp.statusCode != 200) {
      if (kDebugMode) debugPrint('[SoundCloud] Поиск вернул HTTP ${resp.statusCode}');
      return const [];
    }

    return parseTracks(resp.data, limit);
  }

  Future<List<Track>> _searchWith(
    String clientId,
    String q,
    int limit,
  ) async {
    final resp = await _dio.get<dynamic>(
      '$_apiBase/search/tracks',
      queryParameters: {'q': q, 'client_id': clientId, 'limit': limit},
    );
    if (resp.statusCode != 200) return const [];
    return parseTracks(resp.data, limit);
  }

  Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  List<Track> parseTracks(Object? data, int limit) {
    final map = _asMap(data);
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

      // ИСПРАВЛЕНИЕ: Отфильтровываем зашифрованные транскодинги (cbc-encrypted-hls)
      final transcodings = <Map<String, dynamic>>[];
      for (final t in rawTranscodings) {
        if (t is Map) {
          final url = t['url'];
          final format = t['format'];
          final protocol = (format is Map ? format['protocol'] as String? : '') ?? '';

          // Игнорируем DRM-зашифрованные стримы, которые ExoPlayer не может расшифровать
          if (protocol.contains('encrypted')) continue;

          if (url is String && url.isNotEmpty) {
            transcodings.add(Map<String, dynamic>.from(t));
          }
        }
      }

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

      final artworkUrl = _bestArtwork(item);
      final presetKbps = _bitrateFromTranscoding(transcodings.first);

      result.add(
        Track(
          id: trackId,
          sourceId: id,
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

  int? _bitrateFromTranscoding(Map t) {
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

  String? _bestArtwork(Map item) {
    String? raw = item['artwork_url'] as String?;
    if (raw == null || raw.isEmpty) {
      final user = item['user'];
      raw = user is Map ? user['avatar_url'] as String? : null;
    }
    if (raw == null || raw.isEmpty) return null;
    return raw.replaceAll('-large.', '-t500x500.');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ОБОГАЩЕНИЕ ОБЛОЖКАМИ
  // ═══════════════════════════════════════════════════════════════════

  void enrichArtworksInBackground(
    List<Track> tracks,
    void Function(List<Track> updated) onUpdate,
  ) {
    final mutable = List<Track>.of(tracks);
    unawaited(_enrichArtworks(mutable, onUpdate));
  }

  Future<void> _enrichArtworks(
    List<Track> tracks,
    void Function(List<Track> updated) onUpdate,
  ) async {
    const concurrency = 2;
    var index = 0;

    Timer? notifyTimer;
    void scheduleNotify() {
      notifyTimer?.cancel();
      notifyTimer = Timer(const Duration(milliseconds: 50), () {
        onUpdate(List<Track>.of(tracks));
      });
    }

    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= tracks.length) return;
        final t = tracks[i];
        if (t.artworkUrl != null && t.artworkUrl!.isNotEmpty) continue;
        try {
          final url = await ArtworkProvider.instance
              .findArtwork(t.artist, t.title)
              .timeout(const Duration(seconds: 8));
          if (url != null && url.isNotEmpty) {
            tracks[i] = t.copyWith(artworkUrl: url);
            scheduleNotify();
          }
        } on TimeoutException {
          // Таймаут при поиске обложки — пропускаем трек
        } catch (_) {
          // Прочие ошибки поиска обложки игнорируем
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    notifyTimer?.cancel();
    onUpdate(List<Track>.of(tracks));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  СТРИМ И РЕЗОЛВ ТРАНСКОДИНГОВ
  // ═══════════════════════════════════════════════════════════════════

  Future<String> _resolveTranscodingUrl(
    String transcodingUrl, {
    String? trackAuthorization,
  }) async {
    final clientId = await _ensureClientId();
    if (clientId == null) {
      throw StateError('SoundCloud: нет client_id для резолва стрима');
    }

    final queryParams = <String, dynamic>{
      'client_id': clientId,
      if (trackAuthorization != null && trackAuthorization.isNotEmpty)
        'track_authorization': trackAuthorization,
    };

    Future<Response<dynamic>> hit(String cid) => _dio.get<dynamic>(
          transcodingUrl,
          queryParameters: {
            ...queryParams,
            'client_id': cid,
          },
        );

    var resp = await hit(clientId);
    if (resp.statusCode == 401) {
      if (kDebugMode) debugPrint('[SoundCloud] Токен протух (401), инвалидируем client_id...');
      _invalidateClientId();
      final fresh = await _ensureClientId();
      if (fresh != null) resp = await hit(fresh);
    }

    if (resp.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
            '[SoundCloud] ОШИБКА РЕЗОЛВА: HTTP ${resp.statusCode} от $transcodingUrl. Ответ: ${resp.data}');
      }
      throw StateError('HTTP ${resp.statusCode}');
    }

    final map = _asMap(resp.data);
    final url = map?['url'] as String?;
    if (url == null || url.isEmpty) {
      throw StateError('В ответе нет параметра url');
    }
    return url;
  }

  @override
  Future<String> resolveStreamUrl(Track track) async {
    if (kDebugMode) {
      debugPrint('[SoundCloud] Резолв стрима для "${track.artist} - ${track.title}" (ID: ${track.id})');
    }

    final rawTranscodings = track.extra['transcodings'] as List?;
    var trackAuth = track.extra['trackAuthorization'] as String?;

    List<Map<String, dynamic>> transcodings = [];

    if (rawTranscodings != null && rawTranscodings.isNotEmpty) {
      for (final t in rawTranscodings) {
        if (t is Map<String, dynamic>) {
          transcodings.add(t);
        } else if (t is Map) {
          transcodings.add(Map<String, dynamic>.from(t));
        }
      }
    }

    // Исключаем зашифрованные потоки
    transcodings.removeWhere((t) {
      final format = t['format'];
      final protocol = (format is Map ? format['protocol'] as String? : '') ?? '';
      return protocol.contains('encrypted');
    });

    if (transcodings.isEmpty) {
      if (kDebugMode) debugPrint('[SoundCloud] Незашифрованные транскодинги отсутствуют в extra. Запрашиваем через API...');
      final resolvedData = await _fetchTranscodingsForTrack(track);
      if (resolvedData != null) {
        transcodings = resolvedData.transcodings;
        trackAuth ??= resolvedData.trackAuthorization;
      }
    }

    if (transcodings.isEmpty) {
      throw StateError(
          'SoundCloud: Для трека "${track.artist} - ${track.title}" нет доступных незашифрованных потоков.');
    }

    // Сортируем: сначала пробуем MP3 (progressive), затем стандартный HLS
    transcodings.sort((a, b) {
      final protoA = (a['format'] is Map ? a['format']['protocol'] : '') ?? '';
      final protoB = (b['format'] is Map ? b['format']['protocol'] : '') ?? '';
      if (protoA == 'progressive' && protoB != 'progressive') return -1;
      if (protoA != 'progressive' && protoB == 'progressive') return 1;
      return 0;
    });

    Object? lastError;
    for (final t in transcodings) {
      final tUrl = t['url'] as String?;
      final protocol = (t['format'] is Map ? t['format']['protocol'] : 'unknown');
      if (tUrl == null || tUrl.isEmpty) continue;

      if (kDebugMode) {
        debugPrint('[SoundCloud] Пробуем транскодинг ($protocol): $tUrl');
      }

      try {
        final cdnUrl = await _resolveTranscodingUrl(
          tUrl,
          trackAuthorization: trackAuth,
        );
        if (kDebugMode) {
          debugPrint('[SoundCloud] УСПЕХ! Получен CDN URL: ${cdnUrl.substring(0, cdnUrl.length > 60 ? 60 : cdnUrl.length)}...');
        }
        return cdnUrl;
      } catch (e) {
        lastError = e;
        if (kDebugMode) {
          debugPrint('[SoundCloud] Транскодинг $protocol не сработал ($e). Пробуем следующий...');
        }
      }
    }

    throw StateError(
        'SoundCloud: Ни один открытый транскодинг не сработал для "${track.artist} - ${track.title}". Ошибка: $lastError');
  }

  Future<_TrackResolvedData?> _fetchTranscodingsForTrack(Track track) async {
    final clientId = await _ensureClientId();
    if (clientId == null) return null;

    try {
      if (kDebugMode) debugPrint('[SoundCloud] GET $_apiBase/tracks/${track.id}');
      final resp = await _dio.get<dynamic>(
        '$_apiBase/tracks/${track.id}',
        queryParameters: {'client_id': clientId},
      );

      if (resp.statusCode == 200) {
        final map = _asMap(resp.data);
        if (map != null) {
          final media = map['media'];
          final rawTranscodings = media is Map ? media['transcodings'] : null;
          final trackAuth = map['track_authorization'] as String?;

          if (rawTranscodings is List && rawTranscodings.isNotEmpty) {
            final transcodings = <Map<String, dynamic>>[];
            for (final t in rawTranscodings) {
              if (t is Map) {
                final format = t['format'];
                final protocol = (format is Map ? format['protocol'] as String? : '') ?? '';
                if (!protocol.contains('encrypted')) {
                  transcodings.add(Map<String, dynamic>.from(t));
                }
              }
            }
            return _TrackResolvedData(
              transcodings: transcodings,
              trackAuthorization: trackAuth,
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SoundCloud] Ошибка запроса трека по ID: $e');
    }

    return _reResolveTranscodingsBySearch(track);
  }

  Future<_TrackResolvedData?> _reResolveTranscodingsBySearch(Track track) async {
    final query = '${track.artist} ${track.title}'.trim();
    if (query.isEmpty) return null;

    try {
      final clientId = await _ensureClientId();
      if (clientId == null) return null;

      final resp = await _dio.get<dynamic>(
        '$_apiBase/search/tracks',
        queryParameters: {'q': query, 'client_id': clientId, 'limit': 10},
      );

      if (resp.statusCode != 200) return null;
      final map = _asMap(resp.data);
      if (map == null) return null;

      final collection = (map['collection'] as List?) ?? const [];
      for (final item in collection) {
        if (item is! Map) continue;
        final media = item['media'];
        final rawTranscodings = media is Map ? media['transcodings'] : null;
        if (rawTranscodings is! List || rawTranscodings.isEmpty) continue;

        final itemId = item['id']?.toString();
        final itemTitle = (item['title'] as String? ?? '').toLowerCase().trim();
        final wantTitle = track.title.toLowerCase().trim();

        if (itemId == track.id || itemTitle == wantTitle) {
          final transcodings = <Map<String, dynamic>>[];
          for (final t in rawTranscodings) {
            if (t is Map) {
              final format = t['format'];
              final protocol = (format is Map ? format['protocol'] as String? : '') ?? '';
              if (!protocol.contains('encrypted')) {
                transcodings.add(Map<String, dynamic>.from(t));
              }
            }
          }
          final trackAuth = item['track_authorization'] as String?;
          return _TrackResolvedData(
            transcodings: transcodings,
            trackAuthorization: trackAuth,
          );
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SoundCloud] Ошибка повторного поиска: $e');
    }
    return null;
  }

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    if (kDebugMode) {
      debugPrint('[SoundCloud] === Запуск воспроизведения: "${track.artist} - ${track.title}" ===');
    }

    final offlineSource = await offline.createOfflineAudioSource(track);
    if (offlineSource != null) {
      return offlineSource;
    }

    try {
      final directUrl = await resolveStreamUrl(track);
      final isHls = directUrl.contains('.m3u8') || directUrl.contains('/hls');

      // ИСПРАВЛЕНИЕ: Передаем 'Accept-Encoding': 'identity', чтобы исключить ZipException в ExoPlayer
      final headers = const {
        'User-Agent': _userAgent,
        'Referer': 'https://soundcloud.com/',
        'Accept-Encoding': 'identity',
      };

      if (isHls) {
        if (kDebugMode) {
          debugPrint('[SoundCloud] Создаем HLS AudioSource.uri');
        }
        return AudioSource.uri(
          Uri.parse(directUrl),
          headers: headers,
          tag: track.globalId,
        );
      }

      if (kDebugMode) {
        debugPrint('[SoundCloud] Создаем LockCachingAudioSource (MP3)');
      }

      final cacheFile = await YoutubeCache.instance.fileForTrack(
        track,
        extension: 'mp3',
      );

      return LockCachingAudioSource(
        Uri.parse(directUrl),
        headers: headers,
        cacheFile: cacheFile,
        tag: track.globalId,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[SoundCloud] Ошибка в createAudioSource: $e');
        debugPrint('$st');
      }
      rethrow;
    }
  }

  static const int _defaultProgressiveKbps = 128;

  @override
  Future<int?> resolveBitrate(Track track) async {
    final dur = track.duration;
    if (dur == null || dur.inSeconds <= 0) {
      return track.qualityScore ?? _defaultProgressiveKbps;
    }

    try {
      final url = await resolveStreamUrl(track);
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
          validateStatus: (code) => code != null && code < 500,
        ),
      );

      int? bytes;

      final contentRange = resp.headers.value('content-range');
      if (contentRange != null) {
        final slash = contentRange.lastIndexOf('/');
        if (slash != -1) {
          bytes = int.tryParse(contentRange.substring(slash + 1).trim());
        }
      }

      if ((bytes == null || bytes <= 0) && resp.statusCode == 200) {
        final lenStr = resp.headers.value('content-length');
        final len = lenStr != null ? int.tryParse(lenStr) : null;
        if (len != null && len > 1) bytes = len;
      }

      final body = resp.data;
      if (body != null) {
        unawaited(body.stream.listen(null, cancelOnError: true).cancel());
      }

      if (bytes == null || bytes <= 0) {
        return track.qualityScore ?? _defaultProgressiveKbps;
      }

      final kbps = (bytes * 8) / dur.inSeconds / 1000;
      return kbps.round();
    } catch (e) {
      return track.qualityScore ?? _defaultProgressiveKbps;
    }
  }

  @override
  Future<void> prefetch(Track track) async {
    await _ensureClientId();
    try {
      await resolveStreamUrl(track);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }
}

class _TrackResolvedData {
  final List<Map<String, dynamic>> transcodings;
  final String? trackAuthorization;

  _TrackResolvedData({
    required this.transcodings,
    this.trackAuthorization,
  });
}
