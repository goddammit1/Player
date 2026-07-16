import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import 'artwork_provider.dart';
import 'track_source.dart';
import '../core/youtube_cache.dart';

/// Источник треков на основе публичного веб-API SoundCloud.
///
/// SoundCloud давно не выдаёт новые официальные API-ключи, но публичный
/// веб-клиент (soundcloud.com) использует `client_id`, который зашит в
/// его JS-бандлы. Мы извлекаем этот `client_id` так же, как это делает
/// любой неофициальный клиент:
///
/// 1. `GET https://soundcloud.com/` → в HTML лежат `script`-теги со
///    `src` на `https://a-v2.sndcdn.com/assets/<hash>.js` бандлы.
/// 2. Скачиваем эти JS-файлы (с конца — нужный `client_id` обычно в
///    последних) и ищем `client_id:"XXXXXXXX"` регуляркой.
/// 3. С этим `client_id` дёргаем `https://api-v2.soundcloud.com`:
///    - поиск: `GET /search/tracks?q=<query>&client_id=<id>&limit=20`
///    - каждый трек содержит title, user.username (артист),
///      duration (мс), artwork_url (готовая обложка!), и
///      `media.transcodings[]` со ссылками на стримы.
///
/// Воспроизведение (вариант progressive/MP3):
/// Среди `media.transcodings` берём формат `protocol == "progressive"`
/// (прямой MP3). Его URL — это «authorized URL», который при GET с тем
/// же `client_id` отдаёт JSON `{"url": "<финальная CDN-ссылка>"}`. Эту
/// CDN-ссылку оборачиваем в [LockCachingAudioSource] (как muzmo) —
/// файл качается один раз, seek мгновенный.
///
/// Обложки SoundCloud отдаёт сам (`artwork_url`), поэтому Genius/iTunes
/// здесь нужен только как фолбэк для треков без обложки.
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
      // Не бросаемся исключениями на не-200 — обрабатываем явно.
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// Извлечённый из JS-бандлов client_id. Резолвится лениво один раз за
  /// сессию.
  String? _clientId;
  Future<String?>? _clientIdFuture;

  @override
  String get id => 'soundcloud';

  @override
  String get displayName => 'SoundCloud';

  // ═══════════════════════════════════════════════════════════════════
  //  CLIENT_ID
  // ═══════════════════════════════════════════════════════════════════

  /// Гарантирует наличие `client_id`. Возвращает null, если извлечь не
  /// удалось (тогда поиск вернёт пустой список — best-effort).
  Future<String?> _ensureClientId() {
    if (_clientId != null) return Future.value(_clientId);
    _clientIdFuture ??= _fetchClientId();
    return _clientIdFuture!;
  }

  /// Парсит главную страницу SoundCloud, находит ссылки на JS-бандлы и
  /// ищет в них `client_id:"..."`.
  Future<String?> _fetchClientId() async {
    try {
      final pageResp = await _dio.get<String>(
        _siteUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final html = pageResp.data;
      if (html == null || html.isEmpty) return null;

      // Все ссылки на JS-бандлы sndcdn. Идём с конца — нужный client_id
      // традиционно лежит в одном из последних бандлов.
      final scriptUrls = RegExp(
        r'<script[^>]+src="(https://[^"]+\.js)"',
        caseSensitive: false,
      ).allMatches(html).map((m) => m.group(1)!).toList();

      for (final url in scriptUrls.reversed) {
        final id = await _extractClientIdFromScript(url);
        if (id != null) {
          _clientId = id;
          if (kDebugMode) {
            debugPrint('[SoundCloud] client_id получен: '
                '${id.substring(0, 6)}...');
          }
          return id;
        }
      }

      debugPrint('[SoundCloud] не удалось извлечь client_id из бандлов');
      return null;
    } catch (e) {
      debugPrint('[SoundCloud] _fetchClientId threw: $e');
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

  /// Сбрасывает закэшированный client_id. Полезно, если он протух
  /// (SoundCloud вернул 401) — следующий запрос извлечёт свежий.
  void _invalidateClientId() {
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

    // client_id протух — обновим и попробуем один раз ещё.
    if (resp.statusCode == 401) {
      _invalidateClientId();
      final fresh = await _ensureClientId();
      if (fresh == null) return const [];
      return _searchWith(fresh, q, limit);
    }

    if (resp.statusCode != 200) return const [];
    return _parseTracks(resp.data, limit);
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
    return _parseTracks(resp.data, limit);
  }

  /// Приводит тело ответа к Map (Dio иногда отдаёт String).
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

  List<Track> _parseTracks(Object? data, int limit) {
    final map = _asMap(data);
    if (map == null) return const [];

    final collection = (map['collection'] as List?) ?? const [];
    final result = <Track>[];

    for (final item in collection) {
      if (item is! Map) continue;
      // Иногда в collection попадают плейлисты/пользователи — нам нужны
      // только треки (у них есть media.transcodings).
      final kind = item['kind'];
      if (kind != null && kind != 'track') continue;

      final media = item['media'];
      final transcodings = media is Map ? media['transcodings'] : null;
      if (transcodings is! List || transcodings.isEmpty) continue;

      // Ищем progressive (MP3) транскодинг.
      final progressive = _findProgressive(transcodings);
      if (progressive == null) continue; // только HLS — пропускаем (вариант 1)

      final progressiveUrl = progressive['url'] as String;
      // Оценка битрейта по метаданным транскодинга — мгновенно и без
      // сетевых запросов (точного битрейта api-v2 не отдаёт).
      final presetKbps = _bitrateFromTranscoding(progressive);

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
            // URL транскодинга (authorized) — резолвим в CDN-ссылку лениво.
            'transcodingUrl': progressiveUrl,
          },
        ),
      );

      if (result.length >= limit) break;
    }

    return result;
  }

  /// Находит progressive-транскодинг (MP3) среди списка. Возвращает всю
  /// Map транскодинга (url, preset, quality, format), а не только URL —
  /// метаданные нужны для оценки битрейта.
  Map? _findProgressive(List transcodings) {
    for (final t in transcodings) {
      if (t is! Map) continue;
      final format = t['format'];
      final protocol = format is Map ? format['protocol'] : null;
      if (protocol == 'progressive') {
        final url = t['url'];
        if (url is String && url.isNotEmpty) return t;
      }
    }
    return null;
  }

  /// Оценивает битрейт (kbps) по метаданным транскодинга SoundCloud.
  ///
  /// Точного битрейта api-v2 не отдаёт, но preset/quality стабильны:
  /// progressive mp3 «sq» — 128 kbps, «hq» (Go+) — 256, opus — ~64.
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

  /// Возвращает лучшую доступную обложку. SoundCloud отдаёт `artwork_url`
  /// в варианте `-large.jpg` (100x100) — апскейлим до `-t500x500.jpg`.
  /// Если у трека нет обложки, берём аватар пользователя.
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
  //  ОБОГАЩЕНИЕ ОБЛОЖКАМИ (фолбэк для треков без artwork_url)
  // ═══════════════════════════════════════════════════════════════════

  /// Догружает обложки через [ArtworkProvider] только для тех треков
  /// SoundCloud, у которых её нет. Работа идёт в фоне; по мере находок
  /// вызывается [onUpdate] с обновлённым списком.
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
    const concurrency = 6;
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
              .timeout(const Duration(seconds: 6));
          if (url != null && url.isNotEmpty) {
            tracks[i] = t.copyWith(artworkUrl: url);
            scheduleNotify();
          }
        } catch (_) {
          // best-effort
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    notifyTimer?.cancel();
    onUpdate(List<Track>.of(tracks));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  СТРИМ
  // ═══════════════════════════════════════════════════════════════════

  /// Резолвит финальную CDN-ссылку на MP3.
  ///
  /// `transcodingUrl` — это authorized-endpoint. GET к нему с client_id
  /// отдаёт JSON `{"url": "https://cf-media.sndcdn.com/...mp3?..."}`.
  Future<String> _resolveProgressiveUrl(String transcodingUrl) async {
    final clientId = await _ensureClientId();
    if (clientId == null) {
      throw StateError('SoundCloud: нет client_id для резолва стрима');
    }

    Future<Response<dynamic>> hit(String cid) => _dio.get<dynamic>(
          transcodingUrl,
          queryParameters: {'client_id': cid},
        );

    var resp = await hit(clientId);
    if (resp.statusCode == 401) {
      _invalidateClientId();
      final fresh = await _ensureClientId();
      if (fresh != null) resp = await hit(fresh);
    }

    if (resp.statusCode != 200) {
      throw StateError(
          'SoundCloud: транскодинг вернул HTTP ${resp.statusCode}');
    }

    final map = _asMap(resp.data);
    final url = map?['url'] as String?;
    if (url == null || url.isEmpty) {
      throw StateError('SoundCloud: в ответе транскодинга нет url');
    }
    return url;
  }

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final transcodingUrl = track.extra['transcodingUrl'] as String?;
    if (transcodingUrl != null && transcodingUrl.isNotEmpty) {
      return _resolveProgressiveUrl(transcodingUrl);
    }

    // Трек восстановлен из плейлиста/БД, где extra (а значит и
    // transcodingUrl) не сохраняется — см. Track.toMap(). Заново ищем
    // трек повторным /search по "artist title" и сопоставляем по id.
    final reResolved = await _reResolveTranscodingUrl(track);
    if (reResolved != null && reResolved.isNotEmpty) {
      return _resolveProgressiveUrl(reResolved);
    }

    throw StateError('SoundCloud: не удалось переразрешить stream URL для '
        '"${track.artist} - ${track.title}"');
  }

  /// Повторно находит progressive-transcoding URL для трека без
  /// extra['transcodingUrl']. Делает поиск по "artist title" и ищет
  /// совпадение сначала по точному id, затем по artist+title, иначе —
  /// первый результат. Возвращает null, если ничего не нашли.
  Future<String?> _reResolveTranscodingUrl(Track track) async {
    final query = '${track.artist} ${track.title}'.trim();
    if (query.isEmpty) return null;

    try {
      final clientId = await _ensureClientId();
      if (clientId == null) return null;

      final found = await _searchWith(clientId, query, 20);
      if (found.isEmpty) return null;

      // 1) Точное совпадение по id.
      for (final t in found) {
        if (t.id == track.id) {
          final url = t.extra['transcodingUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      // 2) Фолбэк: совпадение по artist+title (без учёта регистра).
      final wantTitle = track.title.toLowerCase().trim();
      final wantArtist = track.artist.toLowerCase().trim();
      for (final t in found) {
        if (t.title.toLowerCase().trim() == wantTitle &&
            t.artist.toLowerCase().trim() == wantArtist) {
          final url = t.extra['transcodingUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      // 3) Мягкий фолбэк: первый результат.
      final first = found.first.extra['transcodingUrl'] as String?;
      return (first != null && first.isNotEmpty) ? first : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    final directUrl = await resolveStreamUrl(track);

    final cacheFile = await YoutubeCache.instance.fileFor(
      'soundcloud_${track.id}',
      extension: 'mp3',
    );

    return LockCachingAudioSource(
      Uri.parse(directUrl),
      cacheFile: cacheFile,
      tag: track.globalId,
    );
  }

  /// Битрейт progressive mp3 SoundCloud по умолчанию (стандарт «sq»).
  static const int _defaultProgressiveKbps = 128;

  /// Ленивый битрейт для «Деталей трека»: считаем по размеру MP3 и
  /// длительности. Размер узнаём Range-GET с `bytes=0-0`.
  ///
  /// Важно: CDN SoundCloud может проигнорировать Range и ответить `200`
  /// потоком без Content-Length. Поэтому тело читаем как stream (а не
  /// bytes — иначе Dio скачает весь mp3 ради заголовков) и при
  /// неизвестном размере фолбэкаемся на оценку из preset.
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

      // 1) 206: Content-Range: bytes 0-0/123456 → число после '/'.
      final contentRange = resp.headers.value('content-range');
      if (contentRange != null) {
        final slash = contentRange.lastIndexOf('/');
        if (slash != -1) {
          bytes = int.tryParse(contentRange.substring(slash + 1).trim());
        }
      }

      // 2) Фолбэк: Content-Length при полном ответе (200).
      if ((bytes == null || bytes <= 0) && resp.statusCode == 200) {
        final lenStr = resp.headers.value('content-length');
        final len = lenStr != null ? int.tryParse(lenStr) : null;
        if (len != null && len > 1) bytes = len;
      }

      // Заголовки прочитаны — тело не нужно. Обрываем стрим, чтобы CDN,
      // проигнорировавший Range, не лил нам весь файл.
      final body = resp.data;
      if (body != null) {
        unawaited(body.stream.listen(null, cancelOnError: true).cancel());
      }

      if (bytes == null || bytes <= 0) {
        if (kDebugMode) {
          debugPrint('[SoundCloud] resolveBitrate: размер неизвестен '
              '(HTTP ${resp.statusCode}, Content-Range: $contentRange) — '
              'фолбэк на preset');
        }
        return track.qualityScore ?? _defaultProgressiveKbps;
      }

      final kbps = (bytes * 8) / dur.inSeconds / 1000;
      return kbps.round();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SoundCloud] resolveBitrate threw: $e');
      }
      return track.qualityScore ?? _defaultProgressiveKbps;
    }
  }

  @override
  Future<void> prefetch(Track track) async {
    // Прогреваем client_id
    await _ensureClientId();
    
    // Если у трека уже есть transcodingUrl — резолвим финальный CDN-URL
    // и начнём фоновое скачивание через LockCachingAudioSource
    final transcodingUrl = track.extra['transcodingUrl'] as String?;
    if (transcodingUrl != null && transcodingUrl.isNotEmpty) {
      try {
        // Резолвим финальный URL (это самая долгая операция)
        await _resolveProgressiveUrl(transcodingUrl);
      } catch (_) {
        // best-effort, не критично
      }
    }
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }
}
