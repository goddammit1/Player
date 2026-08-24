
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
  /// Возвращает запись (cleanTitle, versionHints), где:
  /// - cleanTitle — заголовок БЕЗ содержимого скобок и feat/ft-хвостов;
  /// - versionHints — список слов из скобок/суффикса, которые НЕ являются шумом.
  ///
  /// ПРАВИЛО: «всё, что в скобках», считается хинтом. Из содержимого скобок
  /// исключается только явный шум (feat/ft, prod. by, official video/audio,
  /// lyric video, visualizer, клип/видеоклип, explicit/clean). Всё остальное
  /// (Remix, Club Mix, Extended Mix, Original Mix, Album Version, Cover,
  /// Live, Acoustic, Instrumental, OST, Intro/Outro, Slowed + Reverb, ...) —
  /// хинт и добавляется в поисковый запрос.
  ///
  /// Фразы внутри одних скобок, разделённые `|` или `/` (например,
  /// '(Club Mix | Extended Mix)') считаются ОТДЕЛЬНЫМИ хинтами.
  ///
  /// Примеры:
  /// - 'Исчезаю (Remix)'                 → ('Исчезаю', ['Remix'])
  /// - 'Song (feat. X) (Radio Edit)'     → ('Song', ['Radio Edit'])
  /// - 'Track (feat. John) (prod. by Mike)' → ('Track', [])  // всё шум
  /// - 'Song (Club Mix | Extended Mix)'  → ('Song', ['Club Mix', 'Extended'])
  static ({String cleanTitle, List<String> versionHints}) extractVersionHints(
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
    final cleanTitle = _cleanRequestTitle(title);

    return (cleanTitle: cleanTitle, versionHints: unique);
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
  /// Без версионных хинтов сохраняется прежнее поведение: обратный contains
  /// разрешён, чтобы ловить переименования/сокращения на стороне Genius.
  static bool titleMatches(
    String apiTitle,
    String wantTitleNorm, {
    required bool hasVersionHints,
  }) {
    if (wantTitleNorm.isEmpty) return true;
    final apiNorm = normalize(apiTitle);
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

  static String _cleanRequestTitle(String term) => cleanSearchTerm(term);
}