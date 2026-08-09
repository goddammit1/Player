import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/app_database.dart';

class ArtworkProvider {
  ArtworkProvider._();
  static final ArtworkProvider instance = ArtworkProvider._();

  static const String _geniusToken =
      String.fromEnvironment('GENIUS_TOKEN', defaultValue: '');

  static const String _prefsPrefixBase = 'artwork_v3';

  late final String _prefsPrefix =
      '${_prefsPrefixBase}_${_geniusToken.isEmpty ? 'noauth' : 'auth'}:';

  static final _reParen = RegExp(r'\s*\([^)]*\)');
  static final _reBracket = RegExp(r'\s*\[[^\]]*\]');
  static final _reFeat = RegExp(r'\s+(?:feat|ft)\.?\s+[^&\s].*$', caseSensitive: false);
  static final _reSuffix = RegExp(
    r'\s+-\s+(?:Radio|Club|Extended|Original|Alternative|Acoustic|Instrumental|Live|Remix|Remastered|Demo|Single|EP|Album|Version|Edit|Mix|Cut).*$',
    caseSensitive: false,
  );
  static final _reSpaces = RegExp(r'\s+');
  static final _reNonWord = RegExp(r'[^\w\s]');

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      validateStatus: (_) => true,
    ),
  );

  final Map<String, String> _memCache = {};
  final Map<String, Future<String?>> _inFlight = {};

  /// Сбрасывает in-memory кэш URL обложек, заставляя [findArtwork]
  /// перечитать SQLite и/или перезапросить сеть при следующем вызове.
  void clearMemCache() {
    _memCache.clear();
    _inFlight.clear();
  }

  Future<void> _cacheToDb(String key, String value) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> _cleanupEmptyCache(String rawKey) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.delete(
        'settings',
        where: 'key = ?',
        whereArgs: ['$_prefsPrefix$rawKey'],
      );
    } catch (_) {}
  }

  bool _tokenStatusLogged = false;
  void _logTokenStatusOnce() {
    if (_tokenStatusLogged) return;
    _tokenStatusLogged = true;
    if (_geniusToken.isEmpty) {
      debugPrint(
        '[ArtworkProvider] GENIUS_TOKEN ПУСТОЙ — Genius пропускается, '
        'только iTunes. Пересобери с '
        '--dart-define=GENIUS_TOKEN=<Client Access Token>.',
      );
    } else {
      final masked = _geniusToken.length > 8
          ? '${_geniusToken.substring(0, 4)}...${_geniusToken.substring(_geniusToken.length - 4)}'
          : '***';
      debugPrint(
        '[ArtworkProvider] GENIUS_TOKEN присутствует (len='
        '${_geniusToken.length}, $masked).',
      );
    }
  }

  bool get hasGeniusToken => _geniusToken.isNotEmpty;

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

  String _key(String artist, String title) {
    final a = artist.toLowerCase().trim().replaceAll(_reSpaces, ' ');
    final t = title.toLowerCase().trim().replaceAll(_reSpaces, ' ');
    return '$a|$t';
  }

  List<String> _splitArtists(String artists) {
    return artists
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Нормализует строку для сравнения: убирает non-word символы (в т.ч. *).
  String _normalize(String s) {
    return s.toLowerCase().replaceAll(_reNonWord, '').replaceAll(_reSpaces, ' ').trim();
  }

  Future<String?> findArtwork(String artist, String title) async {
    final key = _key(artist, title);

    final mem = _memCache[key];
    if (mem != null) return mem.isEmpty ? null : mem;

    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['$_prefsPrefix$key'],
      );
      if (rows.isNotEmpty) {
        final saved = rows.first['value'] as String?;
        if (saved != null) {
          _memCache[key] = saved;
          if (saved.isEmpty) {
            // Удаляем «пустой» кэш из БД — он мог остаться от старых версий.
            // После удаления пробуем перезапросить сеть.
            unawaited(_cleanupEmptyCache(key));
            return null;
          }
          return saved;
        }
      }
    } catch (_) {}

    final existing = _inFlight[key];
    if (existing != null) return existing;

    _logTokenStatusOnce();

    final future = _findArtworkNetwork(artist, title, key);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _findArtworkNetwork(
    String artist,
    String title,
    String key,
  ) async {
    final geniusFuture = _safeFetch(() => _fetchGenius(artist, title));
    final itunesFuture = _safeFetch(() => _fetchItunes(artist, title));

    final results = await Future.wait([
      geniusFuture,
      itunesFuture,
    ]);

    final geniusResult = results[0];
    final itunesResult = results[1];

    final geniusError = geniusResult == _networkErrorMarker;
    final itunesError = itunesResult == _networkErrorMarker;

    final url = (geniusResult != null &&
            geniusResult.isNotEmpty &&
            geniusResult != _networkErrorMarker)
        ? geniusResult
        : (itunesResult != null &&
                itunesResult.isNotEmpty &&
                itunesResult != _networkErrorMarker)
            ? itunesResult
            : null;

    final found = url != null && url.isNotEmpty;
    final networkError = geniusError || itunesError;

    if (kDebugMode) {
      debugPrint(
        '[ArtworkProvider] "$artist - $title" -> '
        '${found ? (geniusResult != null && geniusResult != _networkErrorMarker && geniusResult.isNotEmpty ? 'GENIUS' : 'ITUNES') : (networkError ? 'ERROR' : 'NONE')}'
        '${url != null && url.isNotEmpty ? ' ($url)' : ''}',
      );
    }

    if (found) {
      _memCache[key] = url;
      unawaited(
        _cacheToDb('$_prefsPrefix$key', url),
      );
      return url;
    }

    // Пустой результат кэшируем только в память (на сессию).
    // В БД не пишем — чтобы при следующем запуске был шанс перезапросить
    // (актуально для треков, которые могут появиться в Genius позже,
    //  а также для случаев временной недоступности API).
    if (!networkError) {
      _memCache[key] = '';
      // Инвалидируем кэш через 2 минуты — позволяет перезапросить обложку
      // в рамках одной сессии (например, после восстановления сети).
      Timer(const Duration(minutes: 2), () {
        if (_memCache[key] == '') {
          _memCache.remove(key);
        }
      });
    }
    return null;
  }

  static const String _networkErrorMarker = '__NETWORK_ERROR__';

  Future<String?> _safeFetch(Future<String?> Function() fetch) async {
    try {
      return await fetch();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[ArtworkProvider] fetch error: $e');
        debugPrint('$st');
      }
      return _networkErrorMarker;
    }
  }

  // ---------------------------------------------------------------------
  //  Genius
  // ---------------------------------------------------------------------

  Future<String?> _fetchGenius(String artist, String title) async {
    if (_geniusToken.isEmpty) return null;

    final artists = _splitArtists(artist);
    final cleanTitle = _cleanSearchTerm(title);

    // Поиск: все артисты через пробел + title (запятые мешают API)
    final q = '${artists.join(' ')} $cleanTitle'.trim();

    // Для матчинга: нормализованные строки (убираем *, скобки и т.д.)
    final wantTitleNorm = _normalize(_cleanSearchTerm(title));
    final wantArtists = artists.map((a) => a.toLowerCase().trim()).toList();

    final resp = await _dio.get<dynamic>(
      'https://api.genius.com/search',
      queryParameters: {'q': q, 'per_page': 5},
      options: Options(
        headers: {'Authorization': 'Bearer $_geniusToken'},
      ),
    );

    if (resp.statusCode != 200) {
      if (kDebugMode && (resp.statusCode == 401 || resp.statusCode == 403)) {
        debugPrint(
          '[ArtworkProvider] Genius HTTP ${resp.statusCode} — '
          'проверь GENIUS_TOKEN (нужен Client Access Token).',
        );
      }
      throw DioException(
        requestOptions: resp.requestOptions,
        response: resp,
        error: 'Genius HTTP status ${resp.statusCode}',
      );
    }

    final data = _asMap(resp.data);
    if (data == null) return null;

    final hits = (data['response']?['hits'] as List?) ?? const [];
    if (hits.isEmpty) {
      if (kDebugMode) debugPrint('[ArtworkProvider] Genius: пустая выдача для "$q"');
      // Для запросов с кириллицей Genius часто возвращает 0.
      // Пробуем fallback: поиск только по артисту (без тайтла).
      if (_hasCyrillic(q) && artists.isNotEmpty) {
        final fallbackQ = artists.join(' ').trim();
        if (fallbackQ.isNotEmpty && fallbackQ != q) {
          if (kDebugMode) {
            debugPrint('[ArtworkProvider] Genius: retry with artist-only "$fallbackQ"');
          }
          final fbResp = await _dio.get<dynamic>(
            'https://api.genius.com/search',
            queryParameters: {'q': fallbackQ, 'per_page': 5},
            options: Options(
              headers: {'Authorization': 'Bearer $_geniusToken'},
            ),
          );
          if (fbResp.statusCode == 200) {
            final fbData = _asMap(fbResp.data);
            final fbHits = (fbData?['response']?['hits'] as List?) ?? const [];
            if (fbHits.isNotEmpty) {
              if (kDebugMode) {
                debugPrint('[ArtworkProvider] Genius fallback: ${fbHits.length} hits');
              }
              // Продолжаем обработку с fallback-результатами
              return _processGeniusHits(fbHits, wantArtists, wantTitleNorm, isFallback: true);
            }
          }
        }
      }
      return '';
    }

    return _processGeniusHits(hits, wantArtists, wantTitleNorm, isFallback: false);
  }

  /// Проверяет, содержит ли строка кириллические символы.
  static bool _hasCyrillic(String s) {
    return RegExp(r'[а-яё]', caseSensitive: false).hasMatch(s);
  }

  /// Обрабатывает хиты Genius (основной или fallback) и возвращает URL обложки.
  Future<String?> _processGeniusHits(
    List hits,
    List<String> wantArtists,
    String wantTitleNorm, {
    required bool isFallback,
  }) async {
    final candidates = <Map<String, dynamic>>[];
    for (final hit in hits) {
      final result = hit['result'] as Map<String, dynamic>?;
      if (result == null) continue;

      final art = _extractArtworkUrl(result);
      if (art == null || art.isEmpty) continue;

      candidates.add(result);
    }

    if (candidates.isEmpty) return '';

    // Собираем всех артистов из API-ответа
    List<String> extractApiArtists(Map<String, dynamic> result) {
      final list = <String>[];
      final primary = (result['primary_artist']?['name'] as String?)?.toLowerCase().trim();
      if (primary != null && primary.isNotEmpty) list.add(primary);

      final featured = result['featured_artists'] as List?;
      if (featured != null) {
        for (final f in featured) {
          if (f is Map<String, dynamic>) {
            final name = (f['name'] as String?)?.toLowerCase().trim();
            if (name != null && name.isNotEmpty) list.add(name);
          }
        }
      }
      return list;
    }

    bool artistMatch(List<String> apiArtists) {
      if (wantArtists.isEmpty || wantArtists.contains('unknown')) return true;
      for (final want in wantArtists) {
        if (want.isEmpty) continue;
        for (final apiRaw in apiArtists) {
          final api = apiRaw.toLowerCase();
          if (api == want) return true;
          if (want.length > 2 && (api.contains(want) || want.contains(api))) return true;
        }
      }
      return false;
    }

    bool titleMatch(String apiTitle) {
      if (wantTitleNorm.isEmpty) return true;
      final apiNorm = _normalize(apiTitle);
      if (apiNorm == wantTitleNorm) return true;
      if (wantTitleNorm.length > 3 && apiNorm.contains(wantTitleNorm)) return true;
      if (apiNorm.length > 3 && wantTitleNorm.contains(apiNorm)) return true;
      return false;
    }

    Map<String, dynamic>? exactMatch;
    Map<String, dynamic>? partialMatch;
    Map<String, dynamic>? artistFallback;

    for (final result in candidates) {
      final apiArtists = extractApiArtists(result);
      final hasArtist = artistMatch(apiArtists);

      final titleFields = [
        result['title'],
        result['title_with_featured'],
        result['full_title'],
      ];

      bool hasTitle = false;
      for (final raw in titleFields) {
        if (raw is! String) continue;
        if (titleMatch(raw)) {
          hasTitle = true;
          break;
        }
      }

      if (!hasArtist) continue;

      artistFallback ??= result;

      if (!hasTitle) continue;

      final apiTitleNorm = _normalize((result['title'] as String?) ?? '');
      final isExactTitle = apiTitleNorm == wantTitleNorm;
      final isExactArtist = wantArtists.any((w) => apiArtists.any((a) => a == w));

      if (isExactTitle && isExactArtist) {
        exactMatch = result;
        break;
      }
      partialMatch ??= result;
    }

    // Для fallback-запроса (только по артисту) смягчаем требования:
    // если не нашли по тайтлу, берём первого с подходящим артистом.
    // Для обычного запроса artistFallback НЕ применяем — он даёт ложные
    // обложки (например, "Psychosis — Outcast" вместо "Psychosis — Исчезаю").
    final chosen = exactMatch ??
        partialMatch ??
        (isFallback ? artistFallback : null);

    if (chosen == null) return '';

    if (kDebugMode) {
      final matchType = chosen == exactMatch
          ? 'EXACT'
          : (chosen == partialMatch ? 'PARTIAL' : 'ARTIST_FALLBACK');
      final chosenTitle = (chosen['title'] as String?) ?? '?';
      final chosenArtist = (chosen['primary_artist']?['name'] as String?) ?? '?';
      debugPrint(
        '[ArtworkProvider] Genius $matchType: '
        '"$chosenArtist — $chosenTitle"',
      );
    }

    final art = _extractArtworkUrl(chosen);
    if (art == null || art.isEmpty) return '';

    return _geniusSquareUrl(art, size: 600);
  }

  String? _extractArtworkUrl(Map<String, dynamic> result) {
    final songArt = result['song_art_image_url'] as String?;
    if (songArt != null && songArt.isNotEmpty) return songArt;

    final thumb = result['song_art_image_thumbnail_url'] as String?;
    if (thumb != null && thumb.isNotEmpty) return thumb;

    final header = result['header_image_url'] as String?;
    if (header != null && header.isNotEmpty) return header;

    return null;
  }

  String _cleanSearchTerm(String term) {
    var cleaned = term
        .replaceAll(_reParen, '')
        .replaceAll(_reBracket, '')
        .replaceAll(_reFeat, '')
        .replaceAll(_reSuffix, '')
        .trim();
    return cleaned.isEmpty ? term.trim() : cleaned;
  }

  String _geniusSquareUrl(String rawUrl, {required int size}) {
    final base = rawUrl.split('?').first;
    return '$base?w=$size&h=$size&fit=crop&crop=faces,edges';
  }

  // ---------------------------------------------------------------------
  //  iTunes
  // ---------------------------------------------------------------------

  Future<String?> _fetchItunes(String artist, String title) async {
    final artists = _splitArtists(artist);
    final cleanArtist = _cleanSearchTerm(artists.firstOrNull ?? artist);
    final cleanTitle = _cleanSearchTerm(title);
    final term = '$cleanArtist $cleanTitle';

    final resp = await _dio.get<dynamic>(
      'https://itunes.apple.com/search',
      queryParameters: {'term': term, 'entity': 'song', 'limit': 5},
    );

    if (resp.statusCode != 200) return null;

    final data = _asMap(resp.data);
    if (data == null) return null;

    final results = (data['results'] as List?) ?? const [];
    if (results.isEmpty) return '';

    // Фильтруем результаты: артист должен совпадать хотя бы примерно.
    // Без этой проверки iTunes может вернуть подкаст/чужака
    // (пример: "psychosis outcast" → Ncrypta "Psychosis (Podcast Mix)" из
    //  FEARTHEGEAR Podcast).
    final wantArtistsLower = artists.map((a) => a.toLowerCase().trim()).toList();
    Map? best;
    for (final r in results) {
      final rawArt = r['artworkUrl100'] as String?;
      if (rawArt == null || rawArt.isEmpty) continue;
      final apiArtist = ((r['artistName'] as String?) ?? '').toLowerCase().trim();
      // Проверяем: артист совпадает (в любую сторону).
      final artistOk = wantArtistsLower.any(
        (w) => apiArtist.contains(w) || w.contains(apiArtist),
      );
      if (artistOk) {
        best = r;
        break;
      }
      best ??= r; // fallback — первый попавшийся, если ничего не подошло
    }

    if (best == null) return '';
    // Если артист не совпал — не возвращаем fallback.
    // Лучше оставить место для Genius / повторной попытки,
    // чем показать обложку подкаста/чужого трека.
    final bestArtist = ((best['artistName'] as String?) ?? '').toLowerCase().trim();
    final bestArtistOk = wantArtistsLower.any(
      (w) => bestArtist.contains(w) || w.contains(bestArtist),
    );
    if (!bestArtistOk) return '';

    final raw = best['artworkUrl100'] as String?;
    if (raw == null || raw.isEmpty) return '';

    return raw.replaceAll('100x100bb', '600x600bb');
  }
}
