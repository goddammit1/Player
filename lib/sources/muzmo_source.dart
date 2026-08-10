import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:just_audio/just_audio.dart';

import '../core/youtube_cache.dart';
import '../models/track.dart';
import 'artwork_provider.dart';
import 'offline_audio_source.dart' as offline;
import 'track_source.dart';

class MuzmoSource implements TrackSource {
  static const String _baseUrl = 'https://rmr.muzmo.cc';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: true,
      headers: {
        'User-Agent': _userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'ru,en;q=0.9',
        'Referer': '$_baseUrl/',
      },
      validateStatus: (code) => code != null && code < 500,
      responseType: ResponseType.plain,
    ),
  );

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Кэш get_new URL → реальный mp3. Живёт до перезапуска приложения.
  final Map<String, String> _type2Cache = {};

  @override
  String get id => 'muzmo';

  @override
  String get displayName => 'Muzmo';

  MuzmoSource() {
    _dio.interceptors.add(CookieManager(CookieJar()));
  }

  Future<void> _ensureSession() {
    if (_initialized) return Future.value();
    _initFuture ??= () async {
      try {
        await _dio.get<String>('/');
      } catch (_) {}
      _initialized = true;
    }();
    return _initFuture!;
  }

  // ---------------------------------------------------------------------
  //  Поиск + prefetch Type 2 URL'ов
  // ---------------------------------------------------------------------

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    await _ensureSession();

    final resp = await _dio.get<String>('/search', queryParameters: {'q': q});
    if (resp.statusCode != 200 || resp.data == null) return const [];

    final tracks = parseTracks(resp.data!).take(limit).toList();

    // Предзагружаем реальные mp3 для Type 2 в фоне — пока юзер скроллит,
    // ссылки уже будут готовы. Не ждём завершения.
    unawaited(_prefetchType2Urls(tracks));

    if (kDebugMode) {
      debugPrint('[Muzmo] parsed: query="$q" tracks=${tracks.length}');
      for (final t in tracks) {
        final url = t.extra['streamUrl'] as String? ?? '';
        debugPrint('  -> "${t.artist}" — "${t.title}" '
            'url=${url.length > 60 ? '${url.substring(0, 60)}...' : url}');
      }
    }

    return tracks;
  }

  // ---------------------------------------------------------------------
  //  Парсинг HTML
  // ---------------------------------------------------------------------

  List<Track> parseTracks(String htmlText) {
    final doc = html_parser.parse(htmlText);
    final items = doc.querySelectorAll('.item-song');
    final result = <Track>[];

    for (final item in items) {
      String? streamUrl;
      String? trackId;
      String artist = '';
      String title = '';
      Duration? duration;

      // Type 1: td.play с data-file
      final playTd = item.querySelector('td.play');
      if (playTd != null) {
        final dataFile = playTd.attributes['data-file'];
        if (dataFile != null && dataFile.isNotEmpty) {
          streamUrl = normalizeUrl(dataFile);
        }
        trackId = playTd.attributes['id'];

        final dataTitle = playTd.attributes['data-title'] ?? '';
        
        // Исправление 1: Корректная длина сепаратора
        int sepLength = 3;
        int idx = -1;
        for (final sep in [' - ', ' – ', ' — ']) {
          final i = dataTitle.indexOf(sep);
          if (i != -1) {
            idx = i;
            sepLength = sep.length;
            break;
          }
        }
        if (idx > 0) {
          artist = dataTitle.substring(0, idx).trim();
          title = dataTitle.substring(idx + sepLength).trim();
        }
      }

      // Type 2: ссылка get_new
      if (streamUrl == null) {
        final outerLink = item.querySelector('a.block');
        final href = outerLink?.attributes['href'];
        if (href != null && href.contains('get_new')) {
          streamUrl = normalizeUrl(href);
          trackId = href.hashCode.toString();
        }
      }

      if (streamUrl == null || streamUrl.isEmpty) continue;
      trackId ??= streamUrl.hashCode.toString();

      // Исправление 2: Парсинг Artist и Title без потери <b> совпадений
      final artistTitleTd = item.querySelector('td.artist-title');
      if (artistTitleTd != null) {
        final container = artistTitleTd.querySelector('a.block') ?? artistTitleTd;
        
        final boldArtist = container.querySelector('b');
        if (boldArtist != null && boldArtist.text.trim().isNotEmpty) {
          artist = boldArtist.text.trim();
        }

        final htmlContainer = container.innerHtml;
        final brIdx = htmlContainer.indexOf('<br');
        if (brIdx != -1) {
          final titleHtml = htmlContainer.substring(brIdx);
          final titleDoc = html_parser.parseFragment(titleHtml);
          final parsedTitle = titleDoc.text?.trim() ?? '';
          if (parsedTitle.isNotEmpty) {
            title = parsedTitle;
          }
        }
      }

      if (title.isEmpty) continue;
      if (artist.isEmpty) artist = 'Unknown';

      final timeCell = item.querySelector('td.song-time small');
      if (timeCell != null) {
        duration = parseDuration(timeCell.text.trim());
      }

      result.add(Track(
        id: trackId,
        sourceId: id,
        title: title,
        artist: artist,
        duration: duration,
        artworkUrl: null,
        extra: {'streamUrl': streamUrl},
      ));
    }

    return result;
  }

  String normalizeUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    return '$_baseUrl${url.startsWith('/') ? '' : '/'}$url';
  }


  Duration? parseDuration(String s) {
    final parts = s.split(':');
    try {
      if (parts.length == 2) {
        return Duration(minutes: int.parse(parts[0]), seconds: int.parse(parts[1]));
      }
      if (parts.length == 3) {
        return Duration(
          hours: int.parse(parts[0]),
          minutes: int.parse(parts[1]),
          seconds: int.parse(parts[2]),
        );
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------------
  //  Prefetch Type 2 URLs (фоновый резолв get_new → mp3)
  // ---------------------------------------------------------------------

  Future<void> _prefetchType2Urls(List<Track> tracks) async {
    const concurrency = 3;
    var index = 0;

    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= tracks.length) return;

        final t = tracks[i];
        final url = t.extra['streamUrl'] as String?;
        if (url == null || !url.contains('get_new')) continue;
        if (_type2Cache.containsKey(url)) continue;

        try {
          final resolved = await _resolveType2StreamUrl(url);
          if (resolved.isNotEmpty) {
            _type2Cache[url] = resolved;
            // НЕ мутируем tracks[i] — copyWith не знает про extra.
            // resolveStreamUrl сам возьмёт из _type2Cache.
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[Muzmo] prefetch Type 2 failed: $e');
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  // ---------------------------------------------------------------------
  //  resolveStreamUrl
  // ---------------------------------------------------------------------

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final fromExtra = track.extra['streamUrl'] as String?;
    if (fromExtra != null && fromExtra.isNotEmpty) {
      // Type 2: сначала смотрим кэш, потом резолвим
      if (fromExtra.contains('get_new')) {
        final cached = _type2Cache[fromExtra];
        if (cached != null && cached.isNotEmpty) return cached;

        final resolved = await _resolveType2StreamUrl(fromExtra);
        if (resolved.isNotEmpty) {
          _type2Cache[fromExtra] = resolved;
          return resolved;
        }
        throw StateError('Muzmo: не удалось резолвить Type 2 URL');
      }
      // Type 1: прямой mp3
      return fromExtra;
    }

    final reResolved = await _reResolveStreamUrl(track);
    if (reResolved != null && reResolved.isNotEmpty) return reResolved;

    throw StateError('Muzmo: не удалось переразрешить stream URL для '
        '"${track.artist} - ${track.title}"');
  }

  /// Type 2: get_new → 302 → info page → div.play[data-file]
  Future<String> _resolveType2StreamUrl(String getNewUrl) async {
    if (kDebugMode) debugPrint('[Muzmo] resolving Type 2: $getNewUrl');

    final resp1 = await _dio.get<String>(
      getNewUrl,
      options: Options(
        followRedirects: false,
        validateStatus: (code) => code != null && code < 400,
      ),
    );

    String? infoUrl;
    if (resp1.statusCode == 302 || resp1.statusCode == 301) {
      final loc = resp1.headers.value('location');
      if (loc != null && loc.isNotEmpty) {
        infoUrl = loc.startsWith('http') ? loc : '$_baseUrl$loc';
      }
    }

    if (infoUrl == null) {
      throw StateError(
        'Muzmo: get_new не вернул редирект (status ${resp1.statusCode})',
      );
    }

    if (kDebugMode) debugPrint('[Muzmo] Type 2 info page: $infoUrl');

    final resp2 = await _dio.get<String>(infoUrl);
    if (resp2.statusCode != 200 || resp2.data == null) {
      throw StateError('Muzmo: info page недоступна');
    }

    final doc = html_parser.parse(resp2.data!);
    final playDiv = doc.querySelector('div.play');
    if (playDiv == null) {
      throw StateError('Muzmo: div.play не найден на info page');
    }

    final dataFile = playDiv.attributes['data-file'];
    if (dataFile == null || dataFile.isEmpty) {
      throw StateError('Muzmo: data-file пуст на info page');
    }

    final resolved = normalizeUrl(dataFile);
    if (kDebugMode) debugPrint('[Muzmo] Type 2 resolved to: $resolved');
    return resolved;
  }

  /// Повторно находит streamUrl через поиск по artist+title.
  Future<String?> _reResolveStreamUrl(Track track) async {
    final query = '${track.artist} ${track.title}'.trim();
    if (query.isEmpty) return null;

    try {
      await _ensureSession();
      final resp = await _dio.get<String>('/search', queryParameters: {'q': query});
      if (resp.statusCode != 200 || resp.data == null) return null;

      final found = parseTracks(resp.data!);
      if (found.isEmpty) return null;

      for (final t in found) {
        if (t.id == track.id) {
          final url = t.extra['streamUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      final wantTitle = track.title.toLowerCase().trim();
      final wantArtist = track.artist.toLowerCase().trim();
      for (final t in found) {
        if (t.title.toLowerCase().trim() == wantTitle &&
            t.artist.toLowerCase().trim() == wantArtist) {
          final url = t.extra['streamUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      final first = found.first.extra['streamUrl'] as String?;
      return (first != null && first.isNotEmpty) ? first : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  //  CDN resolve + AudioSource
  // ---------------------------------------------------------------------

  Future<String> _resolveCdnUrl(String muzmoUrl) async {
    try {
      final resp = await _dio.get<List<int>>(
        muzmoUrl,
        options: Options(
          headers: {'Referer': '$_baseUrl/', 'Range': 'bytes=0-0'},
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (code) => code != null && code < 400,
        ),
      );

      final location = resp.headers.value('location');
      if (location != null && location.isNotEmpty) {
        return location.startsWith('http') ? location : '$_baseUrl$location';
      }
    } catch (_) {}
    return muzmoUrl;
  }

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    final offlineSource = await offline.createOfflineAudioSource(track);
    if (offlineSource != null) return offlineSource;

    final url = await resolveStreamUrl(track);
    final directUrl = await _resolveCdnUrl(url);

    final cacheFile = await YoutubeCache.instance.fileForTrack(
      track,
      extension: 'mp3',
    );

    return LockCachingAudioSource(
      Uri.parse(directUrl),
      headers: const {
        'User-Agent': _userAgent,
        'Referer': '$_baseUrl/',
      },
      cacheFile: cacheFile,
      tag: track.globalId,
    );
  }

  @override
  Future<void> prefetch(Track track) async {
    await _ensureSession();
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }

  // ---------------------------------------------------------------------
  //  Битрейт
  // ---------------------------------------------------------------------

  @override
  Future<int?> resolveBitrate(Track t) async {
    final dur = t.duration;
    if (dur == null || dur.inSeconds <= 0) return null;

    try {
      final url = await resolveStreamUrl(t);
      final directUrl = await _resolveCdnUrl(url);

      final resp = await _dio.get<ResponseBody>(
        directUrl,
        options: Options(
          headers: {'Range': 'bytes=0-262143'},
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

      if (bytes != null && bytes > 0) {
        unawaited(
            resp.data?.stream.listen(null, cancelOnError: true).cancel());
        final kbps = (bytes * 8) / dur.inSeconds / 1000;
        return kbps.round();
      }

      final head = resp.data == null
          ? const <int>[]
          : await _readUpTo(resp.data!.stream, 256 * 1024);
      return _mp3BitrateFromBytes(head);
    } catch (e) {
      if (kDebugMode) debugPrint('[Muzmo] resolveBitrate threw: $e');
      return null;
    }
  }

  Future<List<int>> _readUpTo(Stream<List<int>> stream, int maxBytes) {
    final collected = <int>[];
    final completer = Completer<List<int>>();
    late StreamSubscription<List<int>> sub;

    void finish() {
      if (!completer.isCompleted) completer.complete(collected);
    }

    sub = stream.listen(
      (chunk) {
        collected.addAll(chunk);
        if (collected.length >= maxBytes) {
          sub.cancel();
          finish();
        }
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub.cancel();
        return collected;
      },
    );
  }

  int? _mp3BitrateFromBytes(List<int> b) {
    var i = 0;

    if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      final tagSize = ((b[6] & 0x7F) << 21) |
          ((b[7] & 0x7F) << 14) |
          ((b[8] & 0x7F) << 7) |
          (b[9] & 0x7F);
      i = 10 + tagSize;
      if (i >= b.length) return null;
    }

    const v1l3 = [
      0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    const v2l3 = [
      0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
    ];

    for (; i + 2 < b.length; i++) {
      if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
      final versionBits = (b[i + 1] >> 3) & 0x03;
      final layerBits = (b[i + 1] >> 1) & 0x03;
      final bitrateIdx = (b[i + 2] >> 4) & 0x0F;
      if (versionBits == 1 || layerBits != 1) continue;
      if (bitrateIdx == 0 || bitrateIdx == 15) continue;
      final kbps = versionBits == 3 ? v1l3[bitrateIdx] : v2l3[bitrateIdx];
      if (kbps > 0) return kbps;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  //  Обложки
  // ---------------------------------------------------------------------

  void enrichArtworksInBackground(
    List<Track> tracks,
    void Function(List<Track> updated) onUpdate,
  ) {
    final mutable = List<Track>.of(tracks);
    unawaited(_enrichArtworks(mutable, onUpdate));
  }

  /// Приоритетный индекс: треки переставляются так, чтобы первые N
  /// (видимая область экрана) обрабатывались раньше остальных.
  /// Это даёт быстрый показ обложек для того, что пользователь уже видит.
  static const int _visibleCount = 8;

  List<int> _priorityIndices(int total) {
    final indices = <int>[];
    // Сначала видимые (0 → _visibleCount-1)
    for (var i = 0; i < total && i < _visibleCount; i++) {
      indices.add(i);
    }
    // Затем остальные
    for (var i = _visibleCount; i < total; i++) {
      indices.add(i);
    }
    return indices;
  }

  Future<void> _enrichArtworks(
    List<Track> tracks, [
    void Function(List<Track> updated)? onUpdate,
  ]) async {
    const concurrency = 6;
    final order = _priorityIndices(tracks.length);
    var pos = 0;

    Timer? notifyTimer;
    void scheduleNotify() {
      if (onUpdate == null) return;
      notifyTimer?.cancel();
      notifyTimer = Timer(const Duration(milliseconds: 50), () {
        onUpdate(List<Track>.of(tracks));
      });
    }

    Future<void> worker() async {
      while (true) {
        final i = pos++;
        if (i >= order.length) return;
        final idx = order[i];
        final t = tracks[idx];
        try {
          final url = await ArtworkProvider.instance
              .findArtwork(t.artist, t.title)
              .timeout(const Duration(seconds: 4));
          if (url != null && url.isNotEmpty) {
            tracks[idx] = t.copyWith(artworkUrl: url);
            scheduleNotify();
            // Прекэшируем картинку (200px — размер для списков),
            // чтобы к моменту перерисовки UI она уже была в дисковом кэше.
            unawaited(_precacheThumb(url));
          }
        } on TimeoutException {
          // best-effort
        } catch (_) {
          // best-effort
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    notifyTimer?.cancel();
    if (onUpdate != null) onUpdate(List<Track>.of(tracks));
  }

  /// Фоновый прекэш уменьшенной обложки в CachedNetworkImage,
  /// чтобы UI показал картинку мгновенно, без второго сетевого круга.
  static final Set<String> _precachedUrls = {};
  static Future<void> _precacheThumb(String url) async {
    if (_precachedUrls.contains(url)) return;
    _precachedUrls.add(url);
    try {
      final provider = CachedNetworkImageProvider(url);
      final config = ImageConfiguration(size: const Size(200, 200));
      final stream = provider.resolve(config);
      final completer = Completer<void>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          info.image.dispose();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e, stack) {
          if (!completer.isCompleted) completer.complete();
        },
      );
      stream.addListener(listener);
      try {
        await completer.future;
      } finally {
        stream.removeListener(listener);
      }
    } catch (_) {}
  }
}
