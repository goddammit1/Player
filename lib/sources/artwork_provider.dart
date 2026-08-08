import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  SharedPreferences? _prefs;
  Future<void>? _prefsInit;

  Future<void> _ensurePrefs() {
    _prefsInit ??= () async {
      _prefs = await SharedPreferences.getInstance();
      await _purgeLegacyPrefs();
    }();
    return _prefsInit!;
  }

  static const List<String> _legacyPrefsPrefixes = ['artwork_v1', 'artwork_v2'];

  Future<void> _purgeLegacyPrefs() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final keys = prefs.getKeys();
      for (final k in keys) {
        for (final prefix in _legacyPrefsPrefixes) {
          if (k.startsWith(prefix)) {
            await prefs.remove(k);
            break;
          }
        }
      }
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

    await _ensurePrefs();
    final saved = _prefs?.getString('$_prefsPrefix$key');
    if (saved != null) {
      _memCache[key] = saved;
      return saved.isEmpty ? null : saved;
    }

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
        _prefs?.setString('$_prefsPrefix$key', url) ?? Future.value(),
      );
      return url;
    }

    if (!networkError) {
      _memCache[key] = '';
      unawaited(
        _prefs?.setString('$_prefsPrefix$key', '') ?? Future.value(),
      );
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
      return '';
    }

    final candidates = <Map<String, dynamic>>[];
    for (final hit in hits) {
      final result = hit['result'] as Map<String, dynamic>?;
      if (result == null) continue;

      final art = _extractArtworkUrl(result);
      if (art == null || art.isEmpty) continue;

      candidates.add(result);
    }

    if (candidates.isEmpty) {
      if (kDebugMode) {
        debugPrint('[ArtworkProvider] Genius: нет hits с обложкой для "$q"');
      }
      return '';
    }

    if (kDebugMode) {
      debugPrint('[ArtworkProvider] Genius: ${candidates.length} candidates для "$q"');
      for (final c in candidates) {
        final t = c['title'] as String? ?? '?';
        final a = (c['primary_artist']?['name'] as String?) ?? '?';
        debugPrint('  -> "$a — $t"');
      }
    }

    // Собираем всех артистов из API-ответа: primary + featured
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
        for (final api in apiArtists) {
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

      // Проверяем все варианты title
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

      // Запоминаем первого с совпадающим artist (fallback)
      artistFallback ??= result;

      if (!hasTitle) continue;

      // Проверяем exact: title exact && любой artist exact
      final apiTitleNorm = _normalize((result['title'] as String?) ?? '');
      final isExactTitle = apiTitleNorm == wantTitleNorm;
      final isExactArtist = wantArtists.any((w) => apiArtists.any((a) => a == w));

      if (isExactTitle && isExactArtist) {
        exactMatch = result;
        break;
      }
      partialMatch ??= result;
    }

    // Приоритет: exact → partial → artistFallback (хоть какая-то обложка)
    final chosen = exactMatch ?? partialMatch ?? artistFallback;

    if (chosen == null) {
      if (kDebugMode) {
        debugPrint('[ArtworkProvider] Genius: ни один не подошёл под "$q"');
      }
      return '';
    }

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
      queryParameters: {'term': term, 'entity': 'song', 'limit': 1},
    );

    if (resp.statusCode != 200) return null;

    final data = _asMap(resp.data);
    if (data == null) return null;

    final results = (data['results'] as List?) ?? const [];
    if (results.isEmpty) return '';

    final raw = results.first['artworkUrl100'] as String?;
    if (raw == null || raw.isEmpty) return '';

    return raw.replaceAll('100x100bb', '600x600bb');
  }
}
