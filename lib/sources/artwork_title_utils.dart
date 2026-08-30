
/// Чистые (без сети/кэша/БД) хелперы для поиска/матчинга обложек —
/// выделены из [ArtworkProvider], чтобы провайдер отвечал только за
/// сетевую загрузку и кэш-хранение, а конверсия/нормализация названий
/// была изолирована и покрыта unit-тестами.
///
/// Все методы — статические и чистой функции: без состояния класса.
abstract class ArtworkTitleUtils {
  // -----------------------------------------------------------------
  //  Regex'ы для [_cleanSearchTerm] (удаляют всё содержимое скобок / feat)
  // -----------------------------------------------------------------
  static final _reParen = RegExp(r'\s*\([^)]*\)');
  static final _reBracket = RegExp(r'\s*\[[^\]]*\]');
  static final _reFeat = RegExp(r'\s+(?:feat|ft)\.?\s+[^&\s].*$', caseSensitive: false);
  static final _reSuffix = RegExp(
    r'\s+-\s+.*$',
    caseSensitive: false,
  );

  // -----------------------------------------------------------------
  //  Для [_extractVersionHints]: захват содержимого скобок
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
  /// хинтов» (см. [[ArtworkProvider._fetchGenius]] / [[ArtworkProvider._fetchItunes]]).
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

  // -----------------------------------------------------------------
  //  Классификация содержимого скобок: «версия» vs «часть названия»
  // -----------------------------------------------------------------

  /// Whitelist слов-маркеров версии трека (lowercase, word-boundary матч).
  ///
  /// Если содержимое скобок содержит хотя бы одно из этих слов — скобки
  /// считаются ВЕРСИЕЙ (Remix/Edit/Live/...) и уходят в `versionHints`.
  /// Иначе — ЧАСТЬЮ НАЗВАНИЯ («(Sic)», «(Don't Fear) The Reaper») и уходят
  /// в `titleParts`. Это различие критично для Genius API: скобки в `q`
  /// ломают поиск, а их содержимое-название нужно искать как обычный текст.
  static const List<String> _versionKeywords = [
    'remix', 'mix', 'edit', 'version', 'live', 'acoustic', 'instrumental',
    'cover', 'demo', 'remaster', 'remastered', 'radio', 'extended', 'club',
    'dub', 'vip', 'reprise', 'interlude', 'intro', 'outro', 'ost',
    'soundtrack', 'single', 'album', 'deluxe', 'mono', 'stereo', 'slowed',
    'reverb', 'sped', 'nightcore', 'unplugged', 'session', 'sessions',
    'rework', 'bootleg', 'mashup', 'medley', 'karaoke', 'cappella',
    'orchestral', 'piano', 'symphonic', '8-bit', '8bit', 'lofi', 'lo-fi',
    'phonk', 'drill', 'acapella', 'cut', 'take', 're-recorded',
    'rerecorded', 'redux', 'reimagined', 'stripped', 'demo',
  ];

  /// Год (1900–2099) — маркер версии: «(2001)», «[1999 Remaster]».
  static final _reYear = RegExp(r'\b(?:19|20)\d{2}\b');

  /// True, если содержимое скобок [content] — версия трека, а не часть
  /// названия. Версия = содержит keyword из [_versionKeywords] (word-boundary,
  /// регистронезависимо), ИЛИ год, ИЛИ уже отфильтровано как шум.
  static bool _isVersionContent(String content) {
    if (_reNoiseTag.hasMatch(content)) return true;
    if (_reYear.hasMatch(content)) return true;
    final lower = content.toLowerCase();
    for (final kw in _versionKeywords) {
      if (RegExp('(?:^|\\W)${RegExp.escape(kw)}(?:\\W|\$)').hasMatch(lower)) {
        return true;
      }
    }
    return false;
  }

  static final _reSpaces = RegExp(r'\s+');
  /// Убирает всё, кроме букв/цифр любого алфавита (включая кириллицу),
  /// подчёркивания и пробелов.
  ///
  /// ВАЖНО: `\w` в Dart без флага `unicode: true` матчит только ASCII
  /// `[A-Za-z0-9_]`, из-за чего [_normalize] вырезал кириллицу целиком:
  /// `wantTitleNorm` для русских треков становился пустым, title-матчинг
  /// отключался и Genius отдавал обложку любой страницы артиста (часто —
  /// обложку альбома, в котором есть трек). Свойства `\p{L}`/`\p{N}`
  /// работают только при `unicode: true`.
  static final _reNonWord = RegExp(r'[^\p{L}\p{N}_\s]', unicode: true);

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
  static bool isProviderUrl(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('/') || lower.startsWith('file://')) return false;
    return lower.contains('genius.com') || lower.contains('mzstatic.com');
  }

  /// Нормализует строку для сравнения: убирает non-word символы (в т.ч. *),
  /// сохраняя буквы и цифры ЛЮБЫХ алфавитов (см. [_reNonWord]).
  static String normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(_reNonWord, '')
        .replaceAll(_reSpaces, ' ')
        .trim();
  }

  /// Проверяет, содержит ли строка кириллические символы.
  static bool hasCyrillic(String s) {
    return RegExp(r'[а-яё]', caseSensitive: false).hasMatch(s);
  }

  static String cleanSearchTerm(String term) {
    var cleaned = term
        .replaceAll(_reParen, '')
        .replaceAll(_reBracket, '')
        .replaceAll(_reFeat, '')
        .replaceAll(_reSuffix, '')
        .trim();
    return cleaned.isEmpty ? term.trim() : cleaned;
  }

  /// Извлекает «версионные хинты» из заголовка — слова, которые помогут
  /// Genius/iTunes найти именно ремикс/radio edit/..., а не оригинал.
  ///
  /// Возвращает запись (cleanTitle, versionHints, titleParts), где:
  /// - cleanTitle — заголовок БЕЗ содержимого скобок и feat/ft-хвостов;
  /// - versionHints — список слов из скобок/суффикса, классифицированных
  ///   как ВЕРСИЯ (см. [_versionKeywords]) и не являющихся шумом;
  /// - titleParts — содержимое скобок, классифицированное как ЧАСТЬ НАЗВАНИЯ
  ///   («(Sic)», «(Don't Fear) The Reaper»): не версии и не шум.
  ///
  /// ПРАВИЛО: скобки делятся на три класса:
  /// - ШУМ (feat/ft, prod. by, official video/audio, lyric video, visualizer,
  ///   клип/видеоклип, explicit/clean) — отбрасывается полностью;
  /// - ВЕРСИЯ (содержит keyword из [_versionKeywords] или год) — в versionHints;
  /// - НАЗВАНИЕ (всё остальное) — в titleParts.
  ///
  /// Различие критично для Genius API: скобки в `q` ломают поиск, поэтому
  /// скобки-названия нужно искать как обычный текст без скобок, а не как
  /// хинт версии (иначе «(Sic)» → strict-матчинг отклоняет страницу «Sic»).
  ///
  /// Фразы внутри одних скобок, разделённые `|` или `/` (например,
  /// '(Club Mix | Extended Mix)') считаются ОТДЕЛЬНЫМИ элементами и
  /// классифицируются каждая сама по себе.
  ///
  /// Примеры:
  /// - 'Исчезаю (Remix)'              → cleanTitle='Исчезаю', hints=['Remix'], parts=[]
  /// - '(Sic)'                        → cleanTitle='', hints=[], parts=['Sic']
  /// - "(Don't Fear) The Reaper"      → cleanTitle='The Reaper', parts=["Don't Fear"]
  /// - 'Song (feat. X) (Radio Edit)'  → cleanTitle='Song', hints=['Radio Edit']
  /// - 'Song (2001 Remaster)'         → hints=['2001 Remaster'] (год = версия)
  /// - '(Sic) (Remix)'                → hints=['Remix'], parts=['Sic']
  static ({String cleanTitle, List<String> versionHints, List<String> titleParts})
      extractVersionHints(String title) {
    final hints = <String>[];
    final parts = <String>[];

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
          // Классификация: версия → hints, иначе → часть названия.
          if (_isVersionContent(p)) {
            hints.add(p);
          } else {
            parts.add(p);
          }
        }
      }
    }

    // Захват суффикса после " - ", если он что-то добавляет.
    // ВАЖНО: суффикс «Track - Remix» по-прежнему считается хинтом версии
    // (как раньше), независимо от whitelist — поведение сохранено для
    // обратной совместимости с существующими тестами.
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
    final seenHints = <String>{};
    final uniqueHints =
        hints.where((h) => seenHints.add(h.toLowerCase())).toList();
    final seenParts = <String>{};
    final uniqueParts =
        parts.where((p) => seenParts.add(p.toLowerCase())).toList();

    // Очищенный заголовок
    final cleanTitle = _cleanRequestTitle(title);

    return (
      cleanTitle: cleanTitle,
      versionHints: uniqueHints,
      titleParts: uniqueParts,
    );
  }

  /// Матчит заголовок страницы Genius [apiTitle] с искомым нормализованным
  /// [wantTitleNorm] (заголовок трека + версионные хинты) на целевое имя.
  ///
  /// [hasVersionHints] — мы искали конкретную версию (Remix/Radio Edit/...).
  /// Тогда страница, чьё название лишь короче искомого, НЕ считается
  /// совпадением: у неё обложка альбома/оригинала, которая не соответствует
  /// версии трека. Совпадением считаются только точное равенство и случаи,
  /// когда заголовок страницы полностью содержит искомое название.
  ///
  /// [cleanTitleEmpty] — весь исходный заголовок был в скобках («(Sic)»):
  /// cleanTitle пуст, название целиком ушло в titleParts. В этом случае
  /// «версия» и «название» неразличимы, поэтому strict-ветка hasVersionHints
  /// даёт только false negatives («(Sic)» vs «Sic» отклонялась). Для такого
  /// кейса дополнительно разрешаем:
  /// - обратный contains (apiNorm короче wantTitleNorm);
  /// - словесный матч: все слова wantTitleNorm ⊆ слов apiNorm (порядок и
  ///   скобки не важны).
  ///
  /// Различение версий при cleanTitleEmpty=false СОХРАНЯЕТСЯ: «Believer» для
  /// «Believer (Remix)» по-прежнему отклоняется.
  static bool titleMatches(
    String apiTitle,
    String wantTitleNorm, {
    required bool hasVersionHints,
    bool cleanTitleEmpty = false,
  }) {
    if (wantTitleNorm.isEmpty) return true;
    final apiNorm = normalize(apiTitle);
    if (apiNorm == wantTitleNorm) return true;
    if (wantTitleNorm.length > 3 && apiNorm.contains(wantTitleNorm)) {
      return true;
    }
    if (cleanTitleEmpty) {
      // Весь тайтл был в скобках — «Sic» должно матчить «(Sic)», «(Sic) [Live]».
      if (apiNorm.length > 2 && wantTitleNorm.contains(apiNorm)) {
        return true;
      }
      // Словесный матч: все слова wantTitleNorm есть среди слов apiNorm.
      final wantWords = wantTitleNorm
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toSet();
      if (wantWords.isNotEmpty) {
        final apiWords = apiNorm
            .split(' ')
            .where((w) => w.isNotEmpty)
            .toSet();
        if (wantWords.every(apiWords.contains)) return true;
      }
      return false;
    }
    if (!hasVersionHints &&
        apiNorm.length > 3 &&
        wantTitleNorm.contains(apiNorm)) {
      return true;
    }
    return false;
  }

  // -----------------------------------------------------------------
  //  Генератор вариантов поискового запроса Genius (обход бага скобок)
  // -----------------------------------------------------------------

  /// Пытаться ли вариант с исходными скобками «как есть».
  ///
  /// ВЫКЛЮЧЕНО по умолчанию: Genius API плохо распознаёт скобки в `q`
  /// («slipknot (sic)» → 0 hits, «slipknot sic» → ok), поэтому такой вариант
  /// почти гарантированно тратит HTTP-запрос впустую. Оставлено как флаг на
  /// случай, если API в будущем починят — включается одной строкой.
  static const bool _geniusTryBrackets = false;

  /// Максимум РЕАЛЬНЫХ (дедуплицированных) HTTP-запросов на трек.
  /// Сверх этого варианты отбрасываются, чтобы не раздувать задержку.
  static const int geniusQueryVariantLimit = 4;

  /// Генерирует упорядоченный, дедуплицированный список строк `q` для
  /// Genius search API, обходящий баг со скобками.
  ///
  /// Порядок вариантов (по приоритету):
  /// 1. artists + cleanTitle + versionHints — текущее поведение, всегда;
  /// 2. artists + titleParts + cleanTitle — если есть скобки-названия;
  /// 3. artists + titleParts (без cleanTitle) — если весь тайтл был в скобках;
  /// 4. artists + cleanTitle (без хинтов) — если есть versionHints (retry);
  /// 5. artists + originalTitle со скобками — опционально, за флагом
  ///    [_geniusTryBrackets] (выключен по умолчанию);
  /// 6. artists + originalTitle с «[] → ()» — если были квадратные скобки.
  ///
  /// Правила:
  /// - Дедупликация по нормализованному ключу (lowercase + схлопывание
  ///   пробелов) с сохранением порядка ([LinkedHashSet]);
  /// - Пустые варианты (только артисты, без тайтла/частей/хинтов) НЕ
  ///   добавляются — этот кейс покрывает кириллический artist-only fallback;
  /// - Возвращается не более [geniusQueryVariantLimit] вариантов.
  static List<String> buildGeniusQueryVariants({
    required List<String> artists,
    required String originalTitle,
    required String cleanTitle,
    required List<String> versionHints,
    required List<String> titleParts,
  }) {
    final artistsStr = artists.join(' ').trim();

    String joinParts(List<String> words) {
      final all = <String>[
        if (artistsStr.isNotEmpty) artistsStr,
        ...words.where((w) => w.trim().isNotEmpty),
      ];
      return all.join(' ').replaceAll(_reSpaces, ' ').trim();
    }

    String normKey(String q) =>
        q.toLowerCase().replaceAll(_reSpaces, ' ').trim();

    final seen = <String>{};
    final out = <String>[];

    void add(List<String> words) {
      final q = joinParts(words);
      if (q.isEmpty) return;
      // Не добавляем «только артисты» — это кейс кириллического fallback.
      if (q == artistsStr) return;
      if (seen.add(normKey(q))) out.add(q);
    }

    // 1. Текущее поведение: artists + cleanTitle + versionHints.
    add([cleanTitle, ...versionHints]);
    // 2. Скобки-названия как основной текст: artists + titleParts + cleanTitle.
    if (titleParts.isNotEmpty) {
      add([...titleParts, cleanTitle]);
    }
    // 3. Весь тайтл в скобках: artists + titleParts (без cleanTitle).
    if (cleanTitle.trim().isEmpty && titleParts.isNotEmpty) {
      add(titleParts);
    }
    // 4. Retry без хинтов: artists + cleanTitle.
    if (versionHints.isNotEmpty) {
      add([cleanTitle]);
    }
    // 5. Опционально: исходный тайтл со скобками (выключен — см. флаг).
    if (_geniusTryBrackets) {
      final orig = originalTitle.trim();
      if (orig.isNotEmpty && orig != cleanTitle.trim()) {
        add([orig]);
      }
    }
    // 6. Квадратные скобки → круглые («Song [Live]» → «Song (Live)»).
    if (originalTitle.contains('[') || originalTitle.contains(']')) {
      final swapped = originalTitle
          .replaceAll('[', '(')
          .replaceAll(']', ')')
          .trim();
      if (swapped.isNotEmpty) add([swapped]);
    }

    if (out.length <= geniusQueryVariantLimit) return out;
    return out.sublist(0, geniusQueryVariantLimit);
  }

  static String _cleanRequestTitle(String term) => cleanSearchTerm(term);
}