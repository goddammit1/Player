import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';



/// Поиск обложек для треков, у которых источник (например, Muzmo) их не
/// отдаёт.
///
/// Стратегия:
/// 1. Сначала пробуем Genius API (нужен Client Access Token). Genius
///    очень хорош на западной музыке, отдаёт квадратные крупные арты.
/// 2. Если Genius не нашёл / нет токена / упал — пробуем iTunes Search
///    API. Он публичный, без токенов, отлично покрывает почти всё, в
///    том числе русскую попсу. URL обложки расширяем до 600x600.
/// 3. Результат (включая «не нашлось» как пустую строку) кэшируется:
///    - в RAM на время жизни процесса,
///    - в SharedPreferences между запусками — чтобы не дёргать API
///      повторно для тех же треков.
///
/// Класс — синглтон, инициализируется лениво. Все операции best-effort:
/// при любой ошибке возвращается `null` и трек просто будет показан с
/// дефолтным плейсхолдером.
class ArtworkProvider {
  ArtworkProvider._();
  static final ArtworkProvider instance = ArtworkProvider._();

  /// Genius Client Access Token. Получается на https://genius.com/api-clients.
  /// Задаётся при сборке: `--dart-define=GENIUS_TOKEN=<token>`.
  /// Если токена нет — провайдер тихо пропустит Genius и пойдёт сразу
  /// в iTunes-фолбэк.
  static const String _geniusToken =
      String.fromEnvironment('GENIUS_TOKEN', defaultValue: '');

  // Версия кэша входит в префикс. При смене токена негативные ('')
  // результаты, накопленные БЕЗ Genius, не должны блокировать новый
  // поиск — поэтому ключ зависит от наличия токена.
  static const String _prefsPrefixBase = 'artwork_v3';

  String get _prefsPrefix =>
      '${_prefsPrefixBase}_${_geniusToken.isEmpty ? 'noauth' : 'auth'}:';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      // Не бросаем исключение на 4xx/5xx — обрабатываем сами.
      validateStatus: (_) => true,
    ),
  );

  /// In-memory кеш: ключ -> url ('' означает «искали, не нашли»).
  final Map<String, String> _memCache = {};

  /// In-flight запросы: ключ -> future. Предотвращает дублирование
  /// одновременных поисков одной и той же обложки из разных виджетов.
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

  /// Разовая чистка ключей от старых версий кэша обложек (artwork_v1/v2).
  /// Их формат устарел, а место в SharedPreferences они занимают навсегда.
  static const List<String> _legacyPrefsPrefixes = ['artwork_v1', 'artwork_v2'];

  Future<void> _purgeLegacyPrefs() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final stale = prefs
          .getKeys()
          .where(
            (k) => _legacyPrefsPrefixes.any((prefix) => k.startsWith(prefix)),
          )
          .toList();
      for (final k in stale) {
        await prefs.remove(k);
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

  /// Есть ли токен Genius в текущей сборке.
  bool get hasGeniusToken => _geniusToken.isNotEmpty;

  /// Приводит тело ответа к Map. Некоторые API (в частности iTunes)
  /// отдают JSON с заголовком `text/javascript`, и Dio не парсит его
  /// автоматически — приходит `String`. Декодируем вручную.
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

    // Нормализуем: lowercase + collapse whitespace. Это важно, чтобы
    // «Imagine Dragons» и «imagine  dragons» давали один ключ кэша.
    final a = artist.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    final t = title.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    return '$a|$t';
  }

  /// Получить URL обложки для трека. Возвращает `null`, если ничего не
  /// нашли (или всё упало). Никогда не кидает исключений наружу.
  ///
  /// Кэширование:
  /// - Нашли URL → кэшируем URL (в RAM + prefs).
  /// - Оба API явно вернули пустой результат → кэшируем '' в prefs
  ///   (не дёргаем снова).
  /// - Ошибка сети / таймаут / rate limit → НЕ кэшируем: следующий
  ///   вызов повторит попытку.
  Future<String?> findArtwork(String artist, String title) async {
    final key = _key(artist, title);

    // 1) RAM.
    final mem = _memCache[key];
    if (mem != null) return mem.isEmpty ? null : mem;

    // 2) Persistent.
    await _ensurePrefs();
    final saved = _prefs?.getString('$_prefsPrefix$key');
    if (saved != null) {
      _memCache[key] = saved;
      return saved.isEmpty ? null : saved;
    }

    // 3) Дедупликация in-flight запросов.
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

  /// Сетевой поиск обложки. Запускает Genius и iTunes параллельно и
  /// возвращает первый успешный непустой результат.
  Future<String?> _findArtworkNetwork(
    String artist,
    String title,
    String key,
  ) async {
    String? geniusResult;
    bool geniusError = false;
    try {
      geniusResult = await _fetchGenius(artist, title);
    } catch (e) {
      if (kDebugMode) debugPrint('[ArtworkProvider] Genius threw: $e');
      geniusError = true;
    }

    String? itunesResult;
    bool itunesError = false;
    try {
      itunesResult = await _fetchItunes(artist, title);
    } catch (e) {
      if (kDebugMode) debugPrint('[ArtworkProvider] iTunes threw: $e');
      itunesError = true;
    }

    // Приоритет: Genius, если он вернул непустой результат; иначе iTunes.
    final url = (geniusResult != null && geniusResult.isNotEmpty)
        ? geniusResult
        : (itunesResult != null && itunesResult.isNotEmpty)
            ? itunesResult
            : null;

    final found = url != null && url.isNotEmpty;
    final networkError = geniusError || itunesError;

    debugPrint(
      '[ArtworkProvider] "$artist - $title" -> '
      '${found ? (geniusResult != null && geniusResult.isNotEmpty ? 'GENIUS' : 'ITUNES') : (networkError ? 'ERROR' : 'NONE')}'
      '${url != null && url.isNotEmpty ? ' ($url)' : ''}',
    );

    if (found) {
      _memCache[key] = url;
      unawaited(
        _prefs?.setString('$_prefsPrefix$key', url) ?? Future.value(),
      );
      return url;
    }

    if (!networkError) {
      // Оба API честно ответили «не нашёл» — кэшируем '' в prefs,
      // чтобы не дёргать снова.
      _memCache[key] = '';
      unawaited(
        _prefs?.setString('$_prefsPrefix$key', '') ?? Future.value(),
      );
    }
    // При networkError НЕ кэшируем ничего. Раньше '' попадал в RAM до
    // перезапуска, и после одного таймаута/429 трек оставался без
    // обложки всю сессию — отсюда «то есть, то нет». Теперь следующий
    // поиск просто повторит попытку.
    return null;
  }

  // ---------------------------------------------------------------------
  //  Genius
  // ---------------------------------------------------------------------

  Future<String?> _fetchGenius(String artist, String title) async {
    if (_geniusToken.isEmpty) return null;

    // Чистим title от мусора, который сбивает поиск: (Radio Edit),
    // [Explicit], (feat. ...), (Original Mix) и т.п. Оставляем
    // основной заголовок — это повышает точность матчинга и для
    // Genius, и для iTunes.
    final cleanArtist = _cleanSearchTerm(artist);
    final cleanTitle = _cleanSearchTerm(title);

    final q = '$cleanArtist $cleanTitle';
    final resp = await _dio.get<dynamic>(
      'https://api.genius.com/search/songs',
      queryParameters: {'q': q, 'per_page': 20},
      options: Options(
        headers: {'Authorization': 'Bearer $_geniusToken'},
      ),
    );
    if (resp.statusCode != 200) {

      // 401/403 = неверный/протухший токен. Это самая частая причина
      // «обложки не подтягиваются» — выводим в лог явно.
      if (kDebugMode) {
        debugPrint(
          '[ArtworkProvider] Genius search HTTP ${resp.statusCode} '
          'for "$q". '
          '${resp.statusCode == 401 || resp.statusCode == 403 ? 'Проверь GENIUS_TOKEN (нужен Client Access Token).' : ''}',
        );
      }
      return null;
    }

    final data = _asMap(resp.data);
    if (data == null) return null;

    // 200 + пустая выдача = честное «не нашлось» ('' по контракту
    // findArtwork), а не ошибка — можно кэшировать.
    final hits = (data['response']?['hits'] as List?) ?? const [];
    if (hits.isEmpty) return '';

    // Ищем первый hit, у которого артист похож на запрошенного.
    // Раньше брали hits.first без проверки — из-за этого каверы
    // и ремиксы могли вытеснить оригинальную песню.
    final best = _findBestHit(hits, cleanArtist, cleanTitle);
    if (best == null) return '';

    // Приоритет: song_art_image_url (обложка песни, квадратная).
    // header_image_url — фоновый баннер альбома/артиста, он часто
    // не квадратный и хуже подходит как обложка. Если song_art нет —
    // лучше вернуть пустой результат (уйдёт в iTunes-фолбэк), чем
    // header, который может быть широким баннером.
    final art = best['song_art_image_url'] as String?;
    if (art == null || art.isEmpty) return '';

    // Genius отдаёт оригинальное изображение — оно может быть любого
    // размера. Для квадратной обложки подставляем параметры resize,
    // чтобы получить ровно 600x600 (квадрат, центрированный crop).
    return _geniusSquareUrl(art, size: 600);
  }

  /// Убирает из поискового запроса типичный «мусор», который снижает
  /// точность поиска обложек: (Radio Edit), [Explicit], feat.,
  /// Original Mix, Remix, и т.д.
  ///
  /// Не трогает символ "&" и апострофы — они важны для названий групп
  /// (например, "Simon & Garfunkel").
  String _cleanSearchTerm(String term) {
    var cleaned = term
        // Скобочные суффиксы: (Radio Edit), (feat. ...), (Remix) и т.д.
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        // Квадратные скобки: [Explicit], [Clean], [Bonus Track] и т.д.
        .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
        // feat./ft. с артистом
        .replaceAll(RegExp(r'\s+(?:feat|ft)\.?\s+[^&\s].*$',
            caseSensitive: false), '')
        // Суффиксы через тире: " - Radio Edit", " - Remix", и т.д.
        .replaceAll(RegExp(r'\s+-\s+(?:Radio|Club|Extended|Original|Alternative|Acoustic|Instrumental|Live|Remix|Remastered|Demo|Single|EP|Album|Version|Edit|Mix|Cut).*$',
            caseSensitive: false), '')
        .trim();
    // Если после чистки ничего не осталось — отдаём исходную строку.
    return cleaned.isEmpty ? term.trim() : cleaned;
  }

  /// Ищет среди хитов Genius первый, у которого имя артиста похоже на
  /// запрошенное. Сравнение регистронезависимое, по первому исполнителю
  /// из списка (artist_names обычно "Artist1, Artist2").
  ///
  /// Если ни один hit не подходит по артисту — возвращаем первый
  /// результат как есть (best-effort), но с пониженным приоритетом
  /// проверяем song_art_image_url (см. выше).
  Map<String, dynamic>? _findBestHit(
    List hits,
    String cleanArtist,
    String cleanTitle,
  ) {
    // Для запросов без артиста или с артистом "Unknown" — берём первый.
    final wantArtist = cleanArtist.toLowerCase().trim();
    if (wantArtist.isEmpty || wantArtist == 'unknown') {
      return hits.first['result'] as Map<String, dynamic>?;
    }

    Map<String, dynamic>? firstResult;
    for (final hit in hits) {
      final result = hit['result'] as Map<String, dynamic>?;
      if (result == null) continue;
      firstResult ??= result;

      final artistNames = (result['artist_names'] as String?) ?? '';
      // artist_names — строка вида "Eminem" или "Drake, Rihanna".
      // Разбиваем по запятой и сравниваем каждый элемент.
      final names =
          artistNames.toLowerCase().split(',').map((n) => n.trim()).toList();
      for (final name in names) {
        // Достаточно, чтобы запрошенный артист содержался в одном из
        // имён (или наоборот — имя содержит запрошенного). Это ловит
        // случаи "Eminem" vs "Eminem (feat. Rihanna)".
        if (name.contains(wantArtist) || wantArtist.contains(name)) {
          return result;
        }
      }
    }

    // Ни один hit не подошёл по артисту — отдаём первый (best-effort),
    // но song_art_image_url обязателен (см. выше), так что если у него
    // нет обложки песни, уйдём в iTunes.
    if (kDebugMode) {
      debugPrint(
        '[ArtworkProvider] Genius: ни один hit не совпал по артисту '
        '"$cleanArtist" — фолбэк на первый результат.',
      );
    }
    return firstResult;
  }

  /// Приводит URL Genius-изображения к квадратному тумбнейлу.
  ///
  /// Genius CDN (images.genius.com) поддерживает параметры:
  ///   `?w=<width>&h=<height>&fit=crop&crop=faces,edges`
  ///
  /// Для квадратной обложки используем fit=crop + crop=faces,edges,
  /// чтобы центрировать обрезку на лицах/краях.
  String _geniusSquareUrl(String rawUrl, {required int size}) {
    // Убираем уже существующие query-параметры, если есть.
    final base = rawUrl.split('?').first;
    return '$base?w=$size&h=$size&fit=crop&crop=faces,edges';
  }

  // ---------------------------------------------------------------------
  //  iTunes Search API (fallback, без токена)
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


    // 200 + пустая выдача = честное «не нашлось», а не ошибка.
    final results = (data['results'] as List?) ?? const [];
    if (results.isEmpty) return '';

    final raw = results.first['artworkUrl100'] as String?;
    if (raw == null || raw.isEmpty) return '';

    // iTunes отдаёт 100x100. Поднимаем до 600x600 — обычная замена.
    return raw.replaceAll('100x100bb', '600x600bb');
  }
}
