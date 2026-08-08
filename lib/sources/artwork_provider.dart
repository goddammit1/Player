import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Поиск обложек. Genius + iTunes fallback.
class ArtworkProvider {
  ArtworkProvider._();
  static final ArtworkProvider instance = ArtworkProvider._();

  static const String _geniusToken =
      String.fromEnvironment('GENIUS_TOKEN', defaultValue: '');

  static const String _prefsPrefixBase = 'artwork_v3';

  late final String _prefsPrefix =
      '${_prefsPrefixBase}_${_geniusToken.isEmpty ? 'noauth' : 'auth'}:';

  // --- static final RegExp: компилируем один раз ---
  static final _reParen = RegExp(r'\s*\([^)]*\)');
  static final _reBracket = RegExp(r'\s*\[[^\]]*\]');
  static final _reFeat = RegExp(r'\s+(?:feat|ft)\.?\s+[^&\s].*$', caseSensitive: false);
  static final _reSuffix = RegExp(
    r'\s+-\s+(?:Radio|Club|Extended|Original|Alternative|Acoustic|Instrumental|Live|Remix|Remastered|Demo|Single|EP|Album|Version|Edit|Mix|Cut).*$',
    caseSensitive: false,
  );
  static final _reSpaces = RegExp(r'\s+');

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

  Future<String?> findArtwork(String artist, String title) async {
    final key = _key(artist, title);

    // 1) RAM
    final mem = _memCache[key];
    if (mem != null) return mem.isEmpty ? null : mem;

    // 2) Persistent
    await _ensurePrefs();
    final saved = _prefs?.getString('$_prefsPrefix$key');
    if (saved != null) {
      _memCache[key] = saved;
      return saved.isEmpty ? null : saved;
    }

    // 3) In-flight dedup
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

  /// Запускает Genius и iTunes ПАРАЛЛЕЛЬНО.
  Future<String?> _findArtworkNetwork(
    String artist,
    String title,
    String key,
  ) async {
    // Параллельный запуск обоих провайдеров
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

    // Приоритет: Genius, затем iTunes
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
      // Оба честно ответили «не нашёл»
      _memCache[key] = '';
      unawaited(
        _prefs?.setString('$_prefsPrefix$key', '') ?? Future.value(),
      );
    }
    return null;
  }

  /// Маркер сетевой ошибки, отличный от null и ''.
  static const String _networkErrorMarker = '__NETWORK_ERROR__';

  /// Оборачивает fetch в try/catch, возвращая маркер при ошибке.
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

    final cleanArtist = _cleanSearchTerm(artist);
    final cleanTitle = _cleanSearchTerm(title);
    final q = '$cleanArtist $cleanTitle';

    final resp = await _dio.get<dynamic>(
      'https://api.genius.com/search',
      queryParameters: {'q': q, 'per_page': 5},
      options: Options(
        headers: {'Authorization': 'Bearer $_geniusToken'},
      ),
    );

    // 1. ОШИБКА СЕТИ / АВТОРИЗАЦИИ: Бросаем исключение, чтобы _safeFetch
    // вернул _networkErrorMarker и НЕ заблокировал трек в кэше навсегда.
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

    final wantArtist = cleanArtist.toLowerCase().trim();
    final wantTitle = cleanTitle.toLowerCase().trim();

    // Собираем hits с обложкой
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

    Map<String, dynamic>? exactMatch;
    Map<String, dynamic>? partialMatch;

    for (final result in candidates) {
      final apiArtist =
          ((result['primary_artist']?['name'] as String?) ?? '').toLowerCase().trim();

      // 2. БЕЗОПАСНЫЙ ПОИСК ИСПОЛНИТЕЛЯ: Защита от коротких строк (чтобы 'art' не совпадал с 'Arctic Monkeys')
      final artistMatch = wantArtist.isEmpty ||
          wantArtist == 'unknown' ||
          apiArtist == wantArtist ||
          (wantArtist.length > 3 && (apiArtist.contains(wantArtist) || wantArtist.contains(apiArtist)));

      if (!artistMatch) continue;

      // Проверяем варианты title
      final titleFields = [
        result['title'],
        result['title_with_featured'],
        result['full_title'],
      ];
      for (final raw in titleFields) {
        if (raw is! String) continue;
        final cleanedTitle = _cleanSearchTerm(raw).toLowerCase().trim();

        // 2. БЕЗОПАСНЫЙ ПОИСК НАЗВАНИЯ
        final titleMatch = wantTitle.isEmpty ||
            cleanedTitle == wantTitle ||
            (wantTitle.length > 3 && (cleanedTitle.contains(wantTitle) || wantTitle.contains(cleanedTitle)));

        if (!titleMatch) continue;

        if (cleanedTitle == wantTitle && apiArtist == wantArtist) {
          exactMatch = result;
          break;
        }
        partialMatch ??= result;
      }
      if (exactMatch != null) break;
    }

    // 3. УБРАН ОПАСНЫЙ FALLBACK: Больше не берем `candidates.first`, если ни один результат не подошел!
    final chosen = exactMatch ?? partialMatch;

    if (chosen == null) {
      if (kDebugMode) {
        debugPrint('[ArtworkProvider] Genius: ни один из результатов не подошел под "$wantArtist — $wantTitle"');
      }
      return ''; // Отдаем пустую строку, чтобы включился iTunes fallback
    }

    if (kDebugMode) {
      final matchType = chosen == exactMatch ? 'EXACT' : 'PARTIAL';
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
    // Приоритет отдаем обложке трека/альбома.
    final songArt = result['song_art_image_url'] as String?;
    if (songArt != null && songArt.isNotEmpty) return songArt;

    final thumb = result['song_art_image_thumbnail_url'] as String?;
    if (thumb != null && thumb.isNotEmpty) return thumb;

    // header_image_url берём в последнюю очередь, так как там часто баннеры, а не квадратные обложки
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
    final cleanArtist = _cleanSearchTerm(artist);
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
