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
  SharedPreferences? _prefs;
  Future<void>? _prefsInit;

  Future<void> _ensurePrefs() {
    _prefsInit ??= () async {
      _prefs = await SharedPreferences.getInstance();
    }();
    return _prefsInit!;
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

    _logTokenStatusOnce();

    // 3) Сеть. Сначала Genius, потом iTunes.
    String? url;
    try {
      url = await _fetchGenius(artist, title);
    } catch (e) {
      debugPrint('[ArtworkProvider] Genius threw: $e');
    }
    final geniusFound = url != null && url.isNotEmpty;
    if (!geniusFound) {
      try {
        url = await _fetchItunes(artist, title);
      } catch (e) {
        debugPrint('[ArtworkProvider] iTunes threw: $e');
      }
    }
    debugPrint(
      '[ArtworkProvider] "$artist - $title" -> '
      '${geniusFound ? 'GENIUS' : (url != null && url.isNotEmpty ? 'ITUNES' : 'NONE')}'
      '${url != null && url.isNotEmpty ? ' ($url)' : ''}',
    );


    final toStore = url ?? '';
    _memCache[key] = toStore;
    // Best-effort persist — не ждём ради скорости поиска.
    unawaited(
      _prefs?.setString('$_prefsPrefix$key', toStore) ?? Future.value(),
    );
    return toStore.isEmpty ? null : toStore;
  }

  // ---------------------------------------------------------------------
  //  Genius
  // ---------------------------------------------------------------------

  Future<String?> _fetchGenius(String artist, String title) async {
    if (_geniusToken.isEmpty) return null;

    final q = '$artist $title';
    final resp = await _dio.get<dynamic>(
      'https://api.genius.com/search',
      queryParameters: {'q': q},
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

    final hits = (data['response']?['hits'] as List?) ?? const [];
    if (hits.isEmpty) return null;


    // Genius возвращает самый релевантный результат первым. Берём арт
    // песни (`song_art_image_url`), он почти всегда квадратный и
    // достаточного разрешения. Если его нет — fallback на header.
    final result = hits.first['result'] as Map<String, dynamic>?;
    if (result == null) return null;

    final art =
        (result['song_art_image_url'] as String?) ??
        (result['header_image_url'] as String?);
    if (art == null || art.isEmpty) return null;
    return art;
  }

  // ---------------------------------------------------------------------
  //  iTunes Search API (fallback, без токена)
  // ---------------------------------------------------------------------

  Future<String?> _fetchItunes(String artist, String title) async {
    final term = '$artist $title';
    final resp = await _dio.get<dynamic>(
      'https://itunes.apple.com/search',
      queryParameters: {'term': term, 'entity': 'song', 'limit': 1},
    );
    if (resp.statusCode != 200) return null;
    final data = _asMap(resp.data);
    if (data == null) return null;


    final results = (data['results'] as List?) ?? const [];
    if (results.isEmpty) return null;

    final raw = results.first['artworkUrl100'] as String?;
    if (raw == null || raw.isEmpty) return null;

    // iTunes отдаёт 100x100. Поднимаем до 600x600 — обычная замена.
    return raw.replaceAll('100x100bb', '600x600bb');
  }
}
