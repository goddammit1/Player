import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import 'artwork_provider.dart';
import 'track_source.dart';
import 'youtube_cache.dart';

/// Источник треков на основе сайта rmr.muzmo.cc.
///
/// Логика парсинга:
/// 1. `GET /search?q=<query>` отдаёт обычный HTML-список треков.
/// 2. Перед поиском сервер ставит сессионную куку `sid` (HttpOnly,
///    действует год). `CookieManager` поверх `Dio` подхватывает её
///    автоматически с первого же запроса.
/// 3. Каждый трек в HTML — `<div class="item-song" id="songNNN">` с
///    вложенным `<td class="play" data-file="/get/.../track.mp3"
///    data-title="Artist - Title">`. mp3 — прямой и играется обычным
///    HTTP-клиентом, без HLS, без подписи.
/// 4. Обложек muzmo не даёт — догружаем их асинхронно через
///    [ArtworkProvider] (Genius + iTunes fallback).
///
/// Воспроизведение: оборачиваем mp3 в [LockCachingAudioSource], как и
/// YouTube, чтобы трек скачивался один раз и seek был мгновенным.
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
      },
      // Не бросаемся исключениями на не-200 — обрабатываем явно.
      validateStatus: (code) => code != null && code < 500,
      responseType: ResponseType.plain,
    ),
  );

  bool _initialized = false;
  Future<void>? _initFuture;

  @override
  String get id => 'muzmo';

  @override
  String get displayName => 'Muzmo';

  MuzmoSource() {
    // CookieJar в памяти — кука `sid` живёт до перезапуска приложения,
    // что нас полностью устраивает: на следующий старт сервер просто
    // выдаст новую при первом запросе на «/».
    _dio.interceptors.add(CookieManager(CookieJar()));
  }

  /// Один раз дёргаем «/», чтобы получить сессионную куку `sid`.
  /// Без неё `/search` иногда отдаёт пустой шаблон.
  Future<void> _ensureSession() {
    if (_initialized) return Future.value();
    _initFuture ??= () async {
      try {
        await _dio.get<String>('/');
      } catch (_) {
        // Не критично — попробуем дёрнуть поиск напрямую.
      }
      _initialized = true;
    }();
    return _initFuture!;
  }

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    await _ensureSession();

    final resp = await _dio.get<String>('/search', queryParameters: {'q': q});
    if (resp.statusCode != 200 || resp.data == null) {
      return const [];
    }

    final tracks = _parseTracks(resp.data!).take(limit).toList();

    // Обложки НЕ ждём здесь — иначе UI висит после Enter, пока 20
    // параллельных запросов к Genius/iTunes отработают. Список треков
    // возвращаем сразу; обогащение запускается вызывающей стороной
    // через [enrichArtworksInBackground].
    return tracks;
  }

  /// Запускает асинхронное обогащение списка треков обложками. Каждый
  /// раз, когда обложка для какого-то трека найдена, вызывается
  /// [onUpdate] с новым списком (с тем же порядком, обновлены только
  /// поля artworkUrl). Метод возвращается сразу — работа идёт в фоне.
  void enrichArtworksInBackground(
    List<Track> tracks,
    void Function(List<Track> updated) onUpdate,
  ) {
    final mutable = List<Track>.of(tracks);
    unawaited(_enrichArtworks(mutable, onUpdate));
  }

  /// Парсит HTML страницы поиска muzmo и возвращает треки в исходном
  /// порядке.
  List<Track> _parseTracks(String htmlText) {
    final doc = html_parser.parse(htmlText);
    final items = doc.querySelectorAll('div.item-song');
    final result = <Track>[];

    for (final item in items) {
      // Кнопка play хранит и id, и data-file, и data-title.
      final play = item.querySelector('td.play');
      if (play == null) continue;

      final dataFile = play.attributes['data-file'];
      final trackId = play.attributes['id'];
      if (dataFile == null || dataFile.isEmpty) continue;
      if (trackId == null || trackId.isEmpty) continue;

      // Артист — <b>...</b>, название — текст после <br/> в <a class="block">.
      final titleBlock = item.querySelector('td.artist-title a');
      String artist = '';
      String title = '';
      if (titleBlock != null) {
        final bold = titleBlock.querySelector('b');
        artist = bold?.text.trim() ?? '';

        // Всё, что НЕ внутри <b>, считаем названием. Это самый
        // надёжный способ — у muzmo бывает несколько строк между
        // <br/>, лишние пробелы и т.п.
        final buf = StringBuffer();
        for (final node in titleBlock.nodes) {
          if (node is dom.Element) {
            final tag = node.localName;
            if (tag == 'b' || tag == 'br') continue;
            buf.write(node.text);
          } else if (node is dom.Text) {
            buf.write(node.text);
          }
        }
        title = buf.toString().trim();
      }

      // Фолбэк: если по какой-то причине не вытащили — берём data-title
      // (формат "Artist - Title") и режем по тире.
      if (artist.isEmpty || title.isEmpty) {
        final dataTitle = play.attributes['data-title'] ?? '';
        final idx = dataTitle.indexOf(' - ');
        if (idx > 0) {
          if (artist.isEmpty) artist = dataTitle.substring(0, idx).trim();
          if (title.isEmpty) title = dataTitle.substring(idx + 3).trim();
        } else if (title.isEmpty) {
          title = dataTitle.trim();
        }
      }

      if (title.isEmpty) continue;

      // Длительность — первый <small> в song-time, формат mm:ss.
      Duration? duration;
      final timeCell = item.querySelector('td.song-time small');
      if (timeCell != null) {
        duration = _parseDuration(timeCell.text.trim());
      }

      // Абсолютная ссылка на mp3.
      final streamUrl = dataFile.startsWith('http')
          ? dataFile
          : '$_baseUrl$dataFile';

      result.add(
        Track(
          id: trackId,
          sourceId: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown' : artist,
          duration: duration,
          artworkUrl: null,
          extra: {'streamUrl': streamUrl},
        ),
      );
    }

    return result;
  }

  Duration? _parseDuration(String s) {
    // Поддерживаем mm:ss и hh:mm:ss.
    final parts = s.split(':');
    try {
      if (parts.length == 2) {
        final m = int.parse(parts[0]);
        final sec = int.parse(parts[1]);
        return Duration(minutes: m, seconds: sec);
      }
      if (parts.length == 3) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final sec = int.parse(parts[2]);
        return Duration(hours: h, minutes: m, seconds: sec);
      }
    } catch (_) {}
    return null;
  }

  /// Параллельно (с ограничением concurrency) запрашиваем обложки.
  /// По мере получения каждого URL мутируем элемент списка через
  /// copyWith и пушим обновлённый список через [onUpdate], если он
  /// задан. Без [onUpdate] просто мутируем `tracks` in-place.
  ///
  /// Уведомления через [onUpdate] дебаунсятся (50 мс), чтобы не делать
  /// 20 setState-ов подряд при «пакетном» возврате обложек.
  Future<void> _enrichArtworks(
    List<Track> tracks, [
    void Function(List<Track> updated)? onUpdate,
  ]) async {
    const concurrency = 6;
    var index = 0;

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
        final i = index++;
        if (i >= tracks.length) return;
        final t = tracks[i];
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

    // Финальный push — на случай если последнее обновление пришлось
    // на «хвост» дебаунса.
    notifyTimer?.cancel();
    if (onUpdate != null) onUpdate(List<Track>.of(tracks));
  }

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final fromExtra = track.extra['streamUrl'] as String?;
    if (fromExtra != null && fromExtra.isNotEmpty) return fromExtra;

    // На случай если трек пришёл не из текущей сессии (например,
    // восстановлен из БД) — заново тащим страницу /info, она содержит
    // тот же data-file. Но для MVP достаточно extra['streamUrl'].
    throw StateError('Muzmo track has no stream URL in extra');
  }

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    final url = await resolveStreamUrl(track);
    // Файл muzmo всегда mp3.
    final cacheFile = await YoutubeCache.instance.fileFor(
      'muzmo_${track.id}',
      extension: 'mp3',
    );

    return LockCachingAudioSource(
      Uri.parse(url),
      headers: {
        // Сервер muzmo иногда требует Referer для отдачи mp3.
        'Referer': '$_baseUrl/',
        'User-Agent': _userAgent,
      },
      cacheFile: cacheFile,
      tag: track.globalId,
    );
  }

  @override
  Future<void> prefetch(Track track) async {
    // У muzmo URL уже есть в extra, ничего не нужно резолвить заранее.
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }
}
