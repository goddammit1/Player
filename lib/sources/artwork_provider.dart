import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/app_database.dart';

class ArtworkProvider {
  ArtworkProvider._();
  static final ArtworkProvider instance = ArtworkProvider._();

  static const String _geniusToken =
      String.fromEnvironment('GENIUS_TOKEN', defaultValue: '');

  static const String _prefsPrefixBase = 'artwork_v3';

  late final String _prefsPrefix =
      '${_prefsPrefixBase}_${_geniusToken.isEmpty ? 'noauth' : 'auth'}:';

  // -----------------------------------------------------------------
  //  Regex'ы для _cleanSearchTerm (удаляют всё содержимое скобок / feat)
  // -----------------------------------------------------------------
  static final _reParen = RegExp(r'\s*\([^)]*\)');
  static final _reBracket = RegExp(r'\s*\[[^\]]*\]');
  static final _reFeat = RegExp(r'\s+(?:feat|ft)\.?\s+[^&\s].*$', caseSensitive: false);
  static final _reSuffix = RegExp(
    r'\s+-\s+.*$',
    caseSensitive: false,
  );

  // -----------------------------------------------------------------
  //  Для _extractVersionHints: захват содержимого скобок
  // -----------------------------------------------------------------
  static final _reParenContent = RegExp(r'\(([^)]*)\)');
  static final _reBracketContent = RegExp(r'\[([^\]]*)\]');
  /// Слова/фразы, которые НЕ являются версией трека, а «шум» — их НЕ включаем
  /// в versionHints (не передаём в поисковый запрос Genius/iTunes).
  ///
  /// ПРАВИЛО от пользователя: «всё, что в скобках после трека, — это хинт».
  /// Поэтому шумовым считается ТОЛЬКО то, что заведомо НЕ влияет на обложку:
  /// - feat/ft/Ft. — это про артистов: матчинг по артистам уже отдельно;
  /// - prod. by / produced by — продюсер, не версия;
  /// - official video/audio/lyric/music video/clip, lyric video, video, audio,
  ///   визуализатор, клип, видеоклип — тип контента, не версия обложки;
  /// - explicit/clean — рейтинг цензуры, не версия.
  ///
  /// Всё остальное (Remix, Radio Edit, Club Mix, Extended Mix, Original Mix,
  /// Album Version, Cover, Live, Acoustic, Instrumental, OST, Intro/Outro,
  /// Slowed + Reverb, ...) является ХИНТОМ и попадает в поисковый запрос.
  /// Если Genius/iTunes с хинтами ничего не находят — есть retry «без
  /// хинтов» (см. [_fetchGenius] / [_fetchItunes]).
  ///
  /// Регистро-независимый. Проверяется по WHOLE фразе (после trim).
  static final _reNoiseTag = RegExp(
    r'^(?:feat|ft)\b.*|'
    r'^(?:prod(?:uced)?\.?\s+by|prod\.?)\b.*|'
    r'^(?:official\s+(?:video|audio|lyric|music\s+video|clip)|'
    r'lyric\s+video|visualizer|video|audio|клип|официальный\s+клип|'
    r'премьера\s+клипа|видеоклип|лирик\s+видео|explicit|clean)$',
    caseSensitive: false,
  );

  static final _reSpaces = RegExp(r'\s+');
  /// Убирает всё, кроме букв/цифр любого алфавита (включая кириллицу),
  /// подчёркивания и пробелов.
  ///
  /// ВАЖНО: `\w` в Dart без флага `unicode: true` матчит только ASCII
  /// `[A-Za-z0-9_]`, из-за чего `_normalize` вырезал кириллицу целиком:
  /// `wantTitleNorm` для русских треков становился пустым, title-матчинг
  /// отключался и Genius отдавал обложку любой страницы артиста (часто —
  /// обложку альбома, в котором есть трек). Свойства `\p{L}`/`\p{N}`
  /// работают только при `unicode: true`.
  static final _reNonWord = RegExp(r'[^\p{L}\p{N}_\s]', unicode: true);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
      validateStatus: (_) => true,
    ),
  );

  /// TTL найденных URL обложек. Пока запись свежая — [findArtwork] отдаёт её
  /// из кэша (память/SQLite) без единого запроса в сеть. После истечения URL
  /// считается устаревшим, и следующий вызов [findArtwork] лениво перезапросит
  /// Genius/iTunes — так подхватывается смена обложки на стороне Genius,
  /// не дёргая API на каждый трек при каждом проигрывании.
  static const Duration foundUrlTtl = Duration(days: 7);

  final Map<String, String> _memCache = {};
  /// Момент записи URL в [_memCache] — по нему проверяется [foundUrlTtl]
  /// в рамках одной сессии.
  final Map<String, DateTime> _memStamp = {};
  final Map<String, Future<String?>> _inFlight = {};

  // -------------------------------------------------------------------
  //  Тестовые хуки: подменяют сетевые источники (Genius/iTunes) без HTTP.
  // -------------------------------------------------------------------

  @visibleForTesting
  Future<String?> Function(String artist, String title, int preferredSize)?
      geniusFetcherOverride;

  @visibleForTesting
  Future<String?> Function(String artist, String title, int preferredSize)?
      itunesFetcherOverride;

  /// Сбрасывает in-memory кэш URL обложек, заставляя [findArtwork]
  /// перечитать SQLite и/или перезапросить сеть при следующем вызове.
  void clearMemCache() {
    _memCache.clear();
    _memStamp.clear();
    _inFlight.clear();
  }

  /// Полностью очищает кэш найденных URL обложек: in-memory и SQLite.
  ///
  /// После вызова [findArtwork] перезапросит Genius/iTunes заново, а не вернёт
  /// свежую запись из кэша. Используется при ручной очистке кэша обложек в UI
  /// (см. CachePage) — чтобы «очистить» означало действительно перезапросить
  /// сеть и подхватить самую свежую обложку на стороне провайдера.
  Future<void> clearCache() async {
    clearMemCache();
    try {
      await AppDatabase.instance.clearArtworkCacheDb();
    } catch (_) {}
  }

  /// Тестовый хук: пишет URL прямо в in-memory кэш (как если бы он был
  /// найден через Genius/iTunes и закэширован). Не трогает сеть и БД.
  @visibleForTesting
  void cacheArtworkForTesting(String artist, String title, String url) {
    final key = _key(artist, title);
    _memCache[key] = url;
    _memStamp[key] = DateTime.now();
  }

  /// Тестовый хук: «состаривает» in-memory запись за пределы [foundUrlTtl],
  /// чтобы [findArtwork] при следующем вызове перезапросил сеть/SQLite.
  @visibleForTesting
  void expireArtworkForTesting(String artist, String title) {
    final key = _key(artist, title);
    _memStamp[key] =
        DateTime.now().subtract(foundUrlTtl + const Duration(minutes: 1));
  }

  /// Тестовый хук: пишет URL в SQLite-кэш с заданным моментом нахождения.
  @visibleForTesting
  Future<void> cacheArtworkToDbForTesting(
    String artist,
    String title,
    String url,
    DateTime foundAt,
  ) async {
    await _cacheToDb(
      '$_prefsPrefix${_key(artist, title)}',
      _encodeCacheValue(url, foundAt),
    );
  }

  /// Тестовый хук: полный ключ SQLite-записи кэша для [artist]/[title].
  @visibleForTesting
  String cacheKeyForTesting(String artist, String title) =>
      '$_prefsPrefix${_key(artist, title)}';

  Future<void> _cacheToDb(String key, String value) async {
    try {
      await AppDatabase.instance.setSetting(key, value);
    } catch (_) {}
  }

  Future<void> _cleanupEmptyCache(String rawKey) async {
    try {
      await AppDatabase.instance.removeSetting('$_prefsPrefix$rawKey');
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

  /// True, если [url] — обложка, найденная самим ArtworkProvider
  /// (Genius/iTunes), а не выданная источником трека.
  ///
  /// Такие URL нестабильны (Genius может сменить обложку) и потому:
  /// - сбрасываются при очистке кэша обложек (см. resetAllTrackArtworks);
  /// - перезапрашиваются по TTL при следующем воспроизведении.
  ///
  /// «Родные» обложки источников (SoundCloud `sndcdn.com`, YouTube
  /// `i.ytimg.com`, локальные файлы) стабильны: после очистки дискового
  /// кэша CachedNetworkImage просто скачает их заново по тому же URL,
  /// поэтому сбрасывать и перезапрашивать их не нужно.
  static bool isProviderArtworkUrl(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('/') || lower.startsWith('file://')) return false;
    return lower.contains('genius.com') || lower.contains('mzstatic.com');
  }

  /// Возвращает свежий (TTL не истёк) URL обложки для [artist]/[title] из кэша
  /// (in-memory или SQLite) БЕЗ обращения к сети.
  ///
  /// null — свежего значения нет (запись отсутствует, протухла по
  /// [foundUrlTtl] или в кэше лежит «не найдено»). Тогда следующий вызов
  /// [findArtwork] перезапросит Genius/iTunes.
  ///
  /// Используется для ленивого авто-обновления обложек (плейлисты и история):
  /// - свежий кэш, совпадающий с хранимым URL — менять нечего;
  /// - свежий кэш, отличающийся от хранимого — рассинхрон, URL обновляется
  ///   без сети;
  /// - свежего кэша нет — обложка устарела, перезапрашиваем сеть.
  Future<String?> getFreshCachedArtworkUrl(String artist, String title) async {
    final key = _key(artist, title);
    final now = DateTime.now();

    // In-memory кэш (в рамках сессии) — свежий URL есть.
    final mem = _memCache[key];
    if (mem != null && mem.isNotEmpty) {
      final memAt = _memStamp[key];
      if (memAt != null && now.difference(memAt) < foundUrlTtl) {
        return mem;
      }
    }

    // SQLite-кэш (переживает перезапуски).
    try {
      final saved = await AppDatabase.instance.getSetting('$_prefsPrefix$key');
      if (saved != null && saved.isNotEmpty) {
        final (:url, :foundAt) = _decodeCacheValue(saved);
        if (url != null && url.isNotEmpty) {
          final fresh =
              foundAt == null || now.difference(foundAt) < foundUrlTtl;
          if (fresh) return url;
        }
      }
    } catch (_) {}

    return null;
  }

  /// True, если провайдерская обложка (Genius/iTunes) для [artist]/[title]
  /// «устарела» по TTL — т.е. при следующем обращении [findArtwork] её стоит
  /// перезапросить в сети.
  ///
  /// Эквивалент `getFreshCachedArtworkUrl(...) == null`. Проверяется и
  /// SQLite-кэш (переживает перезапуски), и in-memory кэш.
  Future<bool> isArtworkStaleAsync(String artist, String title) async =>
      (await getFreshCachedArtworkUrl(artist, title)) == null;

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

  /// Прокси для юнит-тестов — вызывает приватный [_extractVersionHints].
  @visibleForTesting
  static ({String cleanTitle, List<String> versionHints}) extractVersionHintsForTest(
    String title,
  ) {
    return _extractVersionHints(title);
  }

  /// Извлекает «версионные хинты» из заголовка — слова, которые помогут
  /// Genius/iTunes найти именно ремикс/radio edit/..., а не оригинал.
  ///
  /// Возвращает запись (cleanTitle, versionHints), где:
  /// - cleanTitle — заголовок БЕЗ содержимого скобок и feat/ft-хвостов;
  /// - versionHints — список слов из скобок/суффикса, которые НЕ являются шумом.
  ///
  /// ПРАВИЛО: «всё, что в скобках», считается хинтом. Из содержимого скобок
  /// исключается только явный шум (feat/ft, prod. by, official video/audio,
  /// lyric video, visualizer, клип/видеоклип, explicit/clean). Всё остальное
  /// (Remix, Radio Edit, Club Mix, Extended Mix, Original Mix, Album Version,
  /// Cover, Live, Acoustic, Instrumental, OST, Intro/Outro, Slowed + Reverb,
  /// ...) — хинт и добавляется в поисковый запрос Genius/iTunes.
  ///
  /// Фразы внутри одних скобок, разделённые `|` или `/` (например,
  /// '(Club Mix | Extended Mix)') считаются ОТДЕЛЬНЫМИ хинтами.
  ///
  /// Примеры:
  /// - 'Исчезаю (Remix)'                  → ('Исчезаю', ['Remix'])
  /// - 'Song (feat. X) (Radio Edit)'      → ('Song', ['Radio Edit'])
  /// - 'Track (feat. John) (prod. by Mike)' → ('Track', [])  // всё шум
  /// - 'Song (Club Mix | Extended Mix)'   → ('Song', ['Club Mix', 'Extended Mix'])
  /// - 'Song (Slowed + Reverb)'           → ('Song', ['Slowed + Reverb'])
  /// - 'Track - Remix'                    → ('Track', ['Remix'])
  /// - 'Обычная песня'                    → ('Обычная песня', [])
  static ({String cleanTitle, List<String> versionHints}) _extractVersionHints(
    String title,
  ) {
    final hints = <String>[];

    // Собираем всё содержимое круглых и квадратных скобок
    for (final re in [_reParenContent, _reBracketContent]) {
      for (final m in re.allMatches(title)) {
        final raw = (m.group(1) ?? '').trim();
        if (raw.isEmpty) continue;
        // Разбиваем по '|', '/' — бывает «(Club Mix | Extended Mix)»
        for (final part in raw.split(RegExp(r'\s*[|/]\s*'))) {
          final p = part.trim();
          if (p.isEmpty) continue;
          // Отбрасываем шум: feat, official video, prod. by и т.п.
          if (_reNoiseTag.hasMatch(p)) continue;
          hints.add(p);
        }
      }
    }

    // Захват суффикса после " - ", если он что-то добавляет.
    // ВАЖНО: берём ВЕСЬ суффикс (не только узкий список слов), и тоже
    // прогоняем через шум-фильтр — «Track - Remix» → 'Remix',
    // «Track - Radio Edit» → [] (radio edit = шум).
    {
      final m = _reSuffix.firstMatch(title);
      if (m != null) {
        final suffix = m.group(0)?.trim() ?? '';
        if (suffix.isNotEmpty) {
          final withoutDash = suffix.replaceFirst(RegExp(r'^\s*-\s*'), '');
          final trimmed = withoutDash.trim();
          if (trimmed.isNotEmpty && !_reNoiseTag.hasMatch(trimmed)) {
            hints.add(trimmed);
          }
        }
      }
    }

    // Удаляем дубликаты с сохранением порядка
    final seen = <String>{};
    final unique = hints.where((h) => seen.add(h.toLowerCase())).toList();

    // Очищенный заголовок
    final cleanTitle = _cleanSearchTerm(title);

    return (cleanTitle: cleanTitle, versionHints: unique);
  }

  /// Нормализует строку для сравнения: убирает non-word символы (в т.ч. *),
  /// сохраняя буквы и цифры ЛЮБЫХ алфавитов (см. [_reNonWord]).
  static String _normalize(String s) {
    return s.toLowerCase().replaceAll(_reNonWord, '').replaceAll(_reSpaces, ' ').trim();
  }

  /// Тестовый хук: приватный [_normalize].
  @visibleForTesting
  static String normalizeForTest(String s) => _normalize(s);

  /// Матчит заголовок страницы Genius [apiTitle] с искомым нормализованным
  /// [wantTitleNorm] (заголовок трека + версионные хинты).
  ///
  /// [hasVersionHints] — мы искали конкретную версию (Remix/Radio Edit/
  /// Club Mix/...). Тогда страница, чьё название лишь короче искомого
  /// (например, оригинал "Believer" для "Believer (Remix)"), НЕ считается
  /// совпадением: у неё обложка альбома/оригинала, которая не соответствует
  /// версии трека. Совпадением считаются только точное равенство и случаи,
  /// когда заголовок страницы полностью содержит искомое название
  /// (например, "Believer (Remix) [feat. X]").
  ///
  /// Без версионных хинтов сохраняется прежнее поведение: обратный contains
  /// разрешён, чтобы ловить переименования/сокращения на стороне Genius.
  @visibleForTesting
  static bool titleMatches(
    String apiTitle,
    String wantTitleNorm, {
    required bool hasVersionHints,
  }) {
    if (wantTitleNorm.isEmpty) return true;
    final apiNorm = _normalize(apiTitle);
    if (apiNorm == wantTitleNorm) return true;
    if (wantTitleNorm.length > 3 && apiNorm.contains(wantTitleNorm)) {
      return true;
    }
    if (!hasVersionHints &&
        apiNorm.length > 3 &&
        wantTitleNorm.contains(apiNorm)) {
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------
  //  TTL-хелперы кэша найденных URL
  // ---------------------------------------------------------------------

  /// Кодирует значение SQLite-кэша: JSON {"u": url, "t": ms-epoch}.
  /// По [foundAt] после перезапуска проверяется TTL записи.
  static String _encodeCacheValue(String url, DateTime foundAt) =>
      jsonEncode({'u': url, 't': foundAt.millisecondsSinceEpoch});

  /// Декодирует значение SQLite-кэша.
  ///
  /// Поддерживает новый формат (JSON с URL и timestamp) и старый — «голый»
  /// URL, сохранённый до введения TTL. Для старых записей timestamp
  /// неизвестен (`foundAt == null`): они считаются свежими и мигрируются
  /// в новый формат при первом чтении, чтобы не устраивать шторм
  /// перезапросов после обновления приложения.
  static ({String? url, DateTime? foundAt}) _decodeCacheValue(String raw) {
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final url = decoded['u'] as String?;
          final t = decoded['t'];
          final ts = switch (t) {
            int i => i,
            num n => n.toInt(),
            _ => null,
          };
          if (url != null && url.isNotEmpty) {
            return (
              url: url,
              foundAt: ts != null
                  ? DateTime.fromMillisecondsSinceEpoch(ts)
                  : null,
            );
          }
        }
      } catch (_) {}
      return (url: null, foundAt: null);
    }
    return (url: raw, foundAt: null);
  }

  /// Кэширует найденный URL: в память (с TTL-меткой) и в SQLite (с
  /// timestamp для проверки [foundUrlTtl] после перезапуска).
  void _cacheFound(String key, String url) {
    final now = DateTime.now();
    _memCache[key] = url;
    _memStamp[key] = now;
    unawaited(_cacheToDb('$_prefsPrefix$key', _encodeCacheValue(url, now)));
  }

  /// Возвращает URL обложки для трека.
  ///
  /// Порядок источников:
  /// 1. in-memory кэш — пока запись не старше [foundUrlTtl], сеть не трогаем;
  /// 2. SQLite-кэш — то же правило TTL, переживает перезапуски;
  /// 3. Genius → iTunes. Если найден новый URL — кэшируется со свежим
  ///    timestamp. Если ничего нового нет (или сеть недоступна), а в SQLite
  ///    лежал устаревший URL — возвращается он как запасной вариант, при
  ///    этом TTL НЕ обновляется, и следующий вызов снова перезапросит сеть.
  Future<String?> findArtwork(String artist, String title, {int preferredSize = 300}) async {
    final key = _key(artist, title);
    final now = DateTime.now();

    // ---- 1. In-memory кэш (на сессию) с TTL ----
    final mem = _memCache[key];
    if (mem != null) {
      if (mem.isEmpty) {
        // Отрицательный результат (обложка не найдена) кэшируется только на
        // 2 минуты — таймер в _findArtworkNetwork сам удалит запись.
        return null;
      }
      final memAt = _memStamp[key];
      if (memAt != null && now.difference(memAt) < foundUrlTtl) {
        return mem;
      }
      // URL устарел — выбрасываем и перезапрашиваем ниже.
      _memCache.remove(key);
      _memStamp.remove(key);
    }

    // ---- 2. SQLite-кэш (переживает перезапуски) с TTL ----
    String? staleFallback;
    try {
      final saved = await AppDatabase.instance.getSetting('$_prefsPrefix$key');
      if (saved != null) {
        if (saved.isEmpty) {
          // Удаляем «пустой» кэш из БД — он мог остаться от старых версий.
          // После удаления пробуем перезапросить сеть.
          unawaited(_cleanupEmptyCache(key));
        } else {
          final (:url, :foundAt) = _decodeCacheValue(saved);
          if (url != null && url.isNotEmpty) {
            final fresh =
                foundAt == null || now.difference(foundAt) < foundUrlTtl;
            if (fresh) {
              _memCache[key] = url;
              _memStamp[key] = now;
              // Старые записи (голый URL без timestamp) мигрируем в новый
              // формат, чтобы TTL отсчитывался от первого чтения.
              if (foundAt == null) {
                unawaited(
                  _cacheToDb('$_prefsPrefix$key', _encodeCacheValue(url, now)),
                );
              }
              return url;
            }
            staleFallback = url;
          }
        }
      }
    } catch (_) {}

    // ---- 3. Сеть (только если свежего значения нет) ----
    final existing = _inFlight[key];
    if (existing != null) return existing;

    _logTokenStatusOnce();

    final future = _findArtworkNetwork(
      artist,
      title,
      key,
      preferredSize,
      staleFallback: staleFallback,
    );
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
    int preferredSize, {
    String? staleFallback,
  }) async {
    // Genius и iTunes запускаем параллельно, но НЕ ждём оба через Future.wait:
    // если Genius уже вернул URL — сразу возвращаем, не дожидаясь iTunes.
    // Это экономит 300–800 мс на трек (iTunes обычно отвечает позже).
    final geniusFuture = _safeFetch(() => _fetchGenius(artist, title, preferredSize));
    final itunesFuture = _safeFetch(() => _fetchItunes(artist, title, preferredSize));

    // Ждём Genius первым.
    final geniusResult = await geniusFuture;

    // Genius дал URL — возвращаем сразу, iTunes не ждём.
    if (geniusResult != null &&
        geniusResult.isNotEmpty &&
        geniusResult != _networkErrorMarker) {
      _cacheFound(key, geniusResult);
      if (kDebugMode) {
        debugPrint(
          '[ArtworkProvider] "$artist - $title" -> GENIUS (early) ($geniusResult)',
        );
      }
      return geniusResult;
    }

    // Genius не дал URL — ждём iTunes.
    final itunesResult = await itunesFuture;
    final geniusError = geniusResult == _networkErrorMarker;
    final itunesError = itunesResult == _networkErrorMarker;

    final url = (itunesResult != null &&
            itunesResult.isNotEmpty &&
            itunesResult != _networkErrorMarker)
        ? itunesResult
        : null;

    final found = url != null && url.isNotEmpty;
    final networkError = geniusError || itunesError;

    if (kDebugMode) {
      debugPrint(
        '[ArtworkProvider] "$artist - $title" -> '
        '${found ? 'ITUNES' : (networkError ? 'ERROR' : 'NONE')}'
        '${url != null && url.isNotEmpty ? ' ($url)' : ''}',
      );
    }

    if (found) {
      _cacheFound(key, url);
      return url;
    }

    // Нового URL нет (не найден или сеть недоступна), но в SQLite лежит
    // устаревший — отдаём его как запасной вариант, чтобы обложка не
    // исчезла из-за сбоя API. TTL при этом НЕ обновляется: следующий
    // вызов снова перезапросит Genius/iTunes.
    if (staleFallback != null && staleFallback.isNotEmpty) {
      return staleFallback;
    }

    // Пустой результат кэшируем только в память (на сессию).
    // В БД не пишем — чтобы при следующем запуске был шанс перезапросить
    // (актуально для треков, которые могут появиться в Genius позже,
    //  а также для случаев временной недоступности API).
    if (!networkError) {
      _memCache[key] = '';
      _memStamp[key] = DateTime.now();
      // Инвалидируем кэш через 2 минуты — позволяет перезапросить обложку
      // в рамках одной сессии (например, после восстановления сети).
      Timer(const Duration(minutes: 2), () {
        if (_memCache[key] == '') {
          _memCache.remove(key);
          _memStamp.remove(key);
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

  Future<String?> _fetchGenius(String artist, String title, int preferredSize) async {
    final override = geniusFetcherOverride;
    if (override != null) return override(artist, title, preferredSize);

    if (_geniusToken.isEmpty) return null;

    final artists = _splitArtists(artist);
    final (:cleanTitle, :versionHints) = _extractVersionHints(title);

    // wantTitleNorm включает хинты — чтобы exactMatch сработал для ремикса
    final wantTitleNorm = _normalize(
      versionHints.isNotEmpty ? '$cleanTitle ${versionHints.join(' ')}' : cleanTitle,
    );
    final wantArtists = artists.map((a) => a.toLowerCase().trim()).toList();

    // Матчим страницы Genius строго, если искали конкретную версию трека
    // (Remix/Radio Edit/...): страница оригинала (например "Believer" для
    // "Believer (Remix)") не должна подставлять свою — часто альбомную —
    // обложку версии, у которой нет своей страницы на Genius.
    final hasVersionHints = versionHints.isNotEmpty;

    Future<(int status, Map<String, dynamic>? data)> searchGenius(String q) async {
      final resp = await _dio.get<dynamic>(
        'https://api.genius.com/search',
        // 10 вместо 5: нужная страница (особенно версия трека) чаще попадает
        // в выдачу, а цена — пара лишних строк в кандидатах.
        queryParameters: {'q': q, 'per_page': 10},
        options: Options(
          headers: {'Authorization': 'Bearer $_geniusToken'},
        ),
      );
      return (resp.statusCode ?? 0, _asMap(resp.data));
    }

    String buildQ(List<String> extraWords) {
      final parts = <String>[...artists, cleanTitle, ...extraWords];
      return parts.where((s) => s.isNotEmpty).join(' ').trim();
    }

    // ---------- запрос №1: с versionHints --------------------------------
    var q = buildQ(versionHints);
    var (status, data) = await searchGenius(q);

    // Если Genius не авторизован — сразу стоп
    if (status == 401 || status == 403) {
      if (kDebugMode) {
        debugPrint(
          '[ArtworkProvider] Genius HTTP $status — '
          'проверь GENIUS_TOKEN (нужен Client Access Token).',
        );
      }
      return null;
    }

    if (status != 200) data = null;

    List hits = (data?['response']?['hits'] as List?) ?? const [];

    // ---------- запрос №2: без хинтов (retry) ----------------------------
    if (hits.isEmpty && versionHints.isNotEmpty) {
      final qNoHints = buildQ([]);
      if (qNoHints != q) {
        if (kDebugMode) {
          debugPrint(
            '[ArtworkProvider] Genius: no hits for "$q", retry without hints "$qNoHints"',
          );
        }
        (status, data) = await searchGenius(qNoHints);
        if (status == 200) {
          hits = (data?['response']?['hits'] as List?) ?? const [];
          q = qNoHints;
        }
      }
    }

    // ---------- запрос №3: только по артисту (кириллический fallback) ----
    // Для результатов ЭТОГО запроса смягчаем матчинг (isFallback: true):
    // если правильной страницы трека нет, берём первый трек артиста. Иначе
    // после ужесточения title-матчинга кириллический fallback перестал бы
    // находить обложки (title-матчинг с непустым wantTitleNorm не проходит).
    var isFallbackQuery = false;
    if (hits.isEmpty && _hasCyrillic(q) && artists.isNotEmpty) {
      final fallbackQ = artists.join(' ').trim();
      if (fallbackQ.isNotEmpty && fallbackQ != q) {
        if (kDebugMode) {
          debugPrint('[ArtworkProvider] Genius: retry with artist-only "$fallbackQ"');
        }
        (status, data) = await searchGenius(fallbackQ);
        if (status == 200) {
          hits = (data?['response']?['hits'] as List?) ?? const [];
          isFallbackQuery = hits.isNotEmpty;
          if (kDebugMode && hits.isNotEmpty) {
            debugPrint('[ArtworkProvider] Genius fallback: ${hits.length} hits');
          }
        }
      }
    }

    if (hits.isEmpty) {
      if (kDebugMode) debugPrint('[ArtworkProvider] Genius: пустая выдача для "$q"');
      return '';
    }

    return _processGeniusHits(
      hits,
      wantArtists,
      wantTitleNorm,
      isFallback: isFallbackQuery,
      hasVersionHints: hasVersionHints,
      preferredSize: preferredSize,
    );
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
    required bool hasVersionHints,
    required bool isFallback,
    int preferredSize = 300,
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
        if (titleMatches(raw, wantTitleNorm, hasVersionHints: hasVersionHints)) {
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

    return _geniusSquareUrl(art, size: preferredSize);
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

  static String _cleanSearchTerm(String term) {
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

  Future<String?> _fetchItunes(String artist, String title, int preferredSize) async {
    final override = itunesFetcherOverride;
    if (override != null) return override(artist, title, preferredSize);

    final artists = _splitArtists(artist);
    final (:cleanTitle, :versionHints) = _extractVersionHints(title);
    final cleanArtist = _cleanSearchTerm(artists.firstOrNull ?? artist);
    final term = '$cleanArtist $cleanTitle ${versionHints.join(' ')}'.trim();

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

    return raw.replaceAll('100x100bb', '${preferredSize}x${preferredSize}bb');
  }
}
