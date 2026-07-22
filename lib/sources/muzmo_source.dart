import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import 'artwork_provider.dart';
import 'track_source.dart';
import '../core/youtube_cache.dart';

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

    // Битрейт здесь НЕ считаем — Range-GET к каждому mp3 замедляет
    // выдачу. Получаем его лениво в «Деталях трека» через
    // [resolveBitrate]. Обложки тоже не ждём (см. ниже).
    return tracks;
  }

  /// Ленивый битрейт для «Деталей трека».
  ///
  /// Порядок:
  /// 1. Переразрешаем streamUrl при необходимости (трек из плейлиста/БД
  ///    приходит без extra — см. Track.toMap) и проходим 302 до прямой
  ///    CDN-ссылки: Range-запрос через кросс-доменный редирект ненадёжен
  ///    (см. комментарий к [_resolveCdnUrl]).
  /// 2. Пытаемся узнать размер файла (Content-Range при 206, иначе
  ///    Content-Length при 200) → kbps = размер*8/длительность.
  /// 3. Если размер неизвестен (сервер игнорирует Range и льёт chunked)
  ///    — читаем первые ~256 КБ и парсим битрейт из заголовка первого
  ///    mp3-кадра (для CBR это точное значение).
  @override
  Future<int?> resolveBitrate(Track t) async {
    final dur = t.duration;
    if (dur == null || dur.inSeconds <= 0) return null;

    try {
      // Не полагаемся на extra['streamUrl'] напрямую: resolveStreamUrl
      // сам возьмёт его из extra или переразрешит повторным поиском.
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

      // 1) Content-Range: bytes 0-262143/123456 → число после '/'.
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

      if (bytes != null && bytes > 0) {
        // Размер известен — тело не нужно, обрываем стрим.
        unawaited(
            resp.data?.stream.listen(null, cancelOnError: true).cancel());
        final kbps = (bytes * 8) / dur.inSeconds / 1000;
        return kbps.round();
      }

      // 3) Размер неизвестен — достаём битрейт из заголовка первого
      // mp3-кадра в начале файла.
      final head = resp.data == null
          ? const <int>[]
          : await _readUpTo(resp.data!.stream, 256 * 1024);
      final parsed = _mp3BitrateFromBytes(head);
      if (parsed == null && kDebugMode) {
        debugPrint('[Muzmo] resolveBitrate: размер неизвестен '
            '(HTTP ${resp.statusCode}) и mp3-кадр не найден '
            '(прочитано ${head.length} байт)');
      }
      return parsed;
    } catch (e) {
      if (kDebugMode) debugPrint('[Muzmo] resolveBitrate threw: $e');
      return null;
    }
  }

  /// Читает из потока не более [maxBytes] и обрывает подписку, чтобы
  /// сервер, игнорирующий Range, не лил нам весь файл.
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

  /// Достаёт битрейт (kbps) из заголовка первого mp3-кадра. Понимает
  /// ID3v2 в начале файла (пропускает тег, если тот поместился в буфер).
  /// Для CBR-файлов muzmo это точное значение битрейта.
  int? _mp3BitrateFromBytes(List<int> b) {
    var i = 0;

    // ID3v2: "ID3" + версия(2) + флаги(1) + размер(4 байта, syncsafe).
    if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      final tagSize = ((b[6] & 0x7F) << 21) |
          ((b[7] & 0x7F) << 14) |
          ((b[8] & 0x7F) << 7) |
          (b[9] & 0x7F);
      i = 10 + tagSize;
      if (i >= b.length) return null; // тег (с обложкой?) больше буфера
    }

    // Таблицы битрейтов Layer III: MPEG1 и MPEG2/2.5.
    const v1l3 = [
      0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    const v2l3 = [
      0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
    ];

    for (; i + 2 < b.length; i++) {
      // Синхрослово кадра: 11 единичных бит.
      if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
      final versionBits = (b[i + 1] >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=2.5
      final layerBits = (b[i + 1] >> 1) & 0x03; // 1=Layer III
      final bitrateIdx = (b[i + 2] >> 4) & 0x0F;
      if (versionBits == 1 || layerBits != 1) continue; // reserved / не L3
      if (bitrateIdx == 0 || bitrateIdx == 15) continue; // free / invalid
      final kbps = versionBits == 3 ? v1l3[bitrateIdx] : v2l3[bitrateIdx];
      if (kbps > 0) return kbps;
    }
    return null;
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
    // 3 вместо 6: в режиме «все источники» воркеры каждого источника
    // работают параллельно, и 6+6 одновременных запросов к Genius
    // стабильно ловили 429 (rate limit).
    const concurrency = 3;
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
          // Без внешнего .timeout(): раньше при медленной сети future
          // «бросался» по таймауту, findArtwork доезжал до конца и клал
          // URL в кэш, но текущая выдача уже не обновлялась — обложка
          // «появлялась» только при следующем поиске. Сам findArtwork
          // ограничен таймаутами Dio (5 сек connect/receive на запрос),
          // так что воркер не зависнет.
          final url =
              await ArtworkProvider.instance.findArtwork(t.artist, t.title);
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

    // Трек пришёл не из текущей сессии: восстановлен из плейлиста/БД,
    // где extra (а значит и streamUrl) не сохраняется — см.
    // Track.toMap(). Заново ищем mp3 повторным запросом /search по
    // "artist title" и сопоставляем по id (например `song79770649`).
    final reResolved = await _reResolveStreamUrl(track);
    if (reResolved != null && reResolved.isNotEmpty) return reResolved;

    throw StateError('Muzmo: не удалось переразрешить stream URL для '
        '"${track.artist} - ${track.title}"');
  }

  /// Повторно находит прямую ссылку на mp3 для трека без extra['streamUrl'].
  ///
  /// Делает обычный поиск по "artist title" и ищет совпадение сначала
  /// по точному id трека (надёжно — id muzmo стабилен), затем как фолбэк
  /// по совпадению artist+title. Возвращает null, если ничего не нашли.
  Future<String?> _reResolveStreamUrl(Track track) async {
    final query = '${track.artist} ${track.title}'.trim();
    if (query.isEmpty) return null;

    try {
      await _ensureSession();
      final resp =
          await _dio.get<String>('/search', queryParameters: {'q': query});
      if (resp.statusCode != 200 || resp.data == null) return null;

      final found = _parseTracks(resp.data!);
      if (found.isEmpty) return null;

      // 1) Точное совпадение по id.
      for (final t in found) {
        if (t.id == track.id) {
          final url = t.extra['streamUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      // 2) Фолбэк: совпадение по artist+title (без учёта регистра).
      final wantTitle = track.title.toLowerCase().trim();
      final wantArtist = track.artist.toLowerCase().trim();
      for (final t in found) {
        if (t.title.toLowerCase().trim() == wantTitle &&
            t.artist.toLowerCase().trim() == wantArtist) {
          final url = t.extra['streamUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }

      // 3) Совсем мягкий фолбэк: первый результат.
      final first = found.first.extra['streamUrl'] as String?;
      return (first != null && first.isNotEmpty) ? first : null;
    } catch (_) {
      return null;
    }
  }

  /// Резолвит финальную (CDN) ссылку на mp3, проходя 302-редирект.
  ///
  /// `rmr.muzmo.cc/get/...` отвечает `302 Found` и `Location:
  /// https://dsN.mzmdl.com/...`. Сам CDN отдаёт mp3 уже без куки и
  /// Referer (проверено curl'ом: `206 Partial Content`, `audio/mpeg`).
  ///
  /// Зачем это нужно: [LockCachingAudioSource] обслуживает Range-запросы
  /// через собственный прокси и НЕ умеет надёжно следовать кросс-доменному
  /// 302 (особенно с проброшенными заголовками Referer/User-Agent). Из-за
  /// этого muzmo-треки в плейлисте/очереди не воспроизводились. Решение —
  /// отдать ему сразу финальный URL CDN, как для YouTube (там URL
  /// googlevideo уже финальный).
  ///
  /// Делаем GET с `Range: bytes=0-0` и `followRedirects: false`, чтобы
  /// прочитать только заголовок `Location`, не качая тело.

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

      // 3xx — берём Location (абсолютный CDN-URL).
      final location = resp.headers.value('location');
      if (location != null && location.isNotEmpty) {
        return location.startsWith('http') ? location : '$_baseUrl$location';
      }
    } catch (_) {
      // Не вышло разрезолвить — отдадим исходный URL, just_audio
      // попробует сам (хуже не будет).
    }
    return muzmoUrl;
  }

  @override
  Future<AudioSource> createAudioSource(Track track) async {
    final url = await resolveStreamUrl(track);
    // Заранее проходим 302 до прямой CDN-ссылки — см. [_resolveCdnUrl].
    final directUrl = await _resolveCdnUrl(url);

    // Файл muzmo всегда mp3.
    final cacheFile = await YoutubeCache.instance.fileFor(
      'muzmo_${track.id}',
      extension: 'mp3',
    );

    // Без headers: CDN ds*.mzmdl.com отдаёт mp3 напрямую, а лишний
    // Referer/User-Agent на CDN только мешает кэширующему прокси
    // just_audio корректно отрабатывать Range-запросы.
    return LockCachingAudioSource(
      Uri.parse(directUrl),
      cacheFile: cacheFile,
      tag: track.globalId,
    );
  }

  @override
  Future<void> prefetch(Track track) async {
    // У muzmo streamUrl уже есть в extra — ничего резолвить не надо.
    // Но можем прогреть сессию (куку sid), если ещё не делали.
    await _ensureSession();
    
    // Опционально: начинаем фоновое скачивание кэш-файла
    // LockCachingAudioSource сам начнёт качать при createAudioSource,
    // но если хотим предзагрузку — нужен полный createAudioSource.
    // Пока ограничимся прогревом сессии.
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }
}
