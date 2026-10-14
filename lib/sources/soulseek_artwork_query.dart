/// Artist/title для поиска обложки (Genius/iTunes) по пути файла Soulseek.
///
/// `Track.artist/title` Soulseek-трека — это «всё после первого ' - '» имени
/// файла и родительский каталог. В запрос обложки попадали альбом, номер
/// трека и папки-свалки («Rihanna - Good Girl Gone Bad - 04 - Breakin'
/// Dishes», «2-03 Paparazzi», «FULL ALBUMS»), и больше половины треков
/// выдачи оставались без обложки, впустую занимая очередь запросов.
/// Отображаемые названия это не меняет — чистится только запрос.
///
/// [fallbackArtist]/[fallbackTitle] (обычно `Track.artist/title`)
/// возвращаются, если из пути ничего осмысленного не извлечь.
({String artist, String title}) soulseekArtworkQuery(
  String remoteFilename, {
  required String fallbackArtist,
  required String fallbackTitle,
}) {
  final parts = remoteFilename
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.trim().isNotEmpty)
      .toList();
  if (parts.isEmpty) return (artist: fallbackArtist, title: fallbackTitle);

  final segments = _segments(_removeExtension(parts.last));
  if (segments.isEmpty) return (artist: fallbackArtist, title: fallbackTitle);

  final title = _stripTags(segments.last);
  // «Artist - [Album - NN -] Title»: исполнитель — первый сегмент, если
  // это не папка-свалка вида «music - 10. Title».
  final first = _stripTags(segments.first);
  final artist = segments.length >= 2 && first.isNotEmpty && !_isGenericFolder(first)
      ? first
      : _artistFromFolders(parts.sublist(0, parts.length - 1)) ??
          fallbackArtist;
  return (
    artist: artist,
    title: title.isNotEmpty ? title : fallbackTitle,
  );
}

/// Сегменты имени файла без номеров трека, годов и тегов качества.
List<String> _segments(String basename) {
  var base = basename.trim();
  if (base.contains(' ')) {
    // «Rihanna_Good Girl Gone Bad - The Remixes_06_Breakin' Dishes»:
    // при наличии пробелов '_' разделяет сегменты.
    base = base.replaceAll('_', ' - ');
  } else if (base.contains('_') || _reStartsWithDigit.hasMatch(base)) {
    // «04-rihanna-breakin_dishes»: без пробелов '-' разделяет сегменты,
    // '_' — слова. Одиночное «Jay-Z» не трогаем.
    base = base.replaceAll('_', ' ').replaceAll('-', ' - ');
  }
  return [
    for (final raw in base.split(_reSeparator))
      if (!_isNoiseSegment(raw.trim()))
        if (_stripTrackNumber(raw.trim()) case final s when s.isNotEmpty) s,
  ];
}

/// Исполнитель по каталогам (ближайший к файлу — последний в [dirs]).
///
/// «Artist - Album (2009)» → Artist; «Artist/Album/» → Artist (каталог над
/// альбомом); каталоги дисков («CD1») пропускаются, папки-свалки («music»,
/// «FULL ALBUMS», «LOSSLESS») не считаются исполнителем.
String? _artistFromFolders(List<String> dirs) {
  final levels = [
    for (final d in dirs.reversed)
      if (!_reDiscFolder.hasMatch(d.trim())) d.trim(),
  ];
  if (levels.isEmpty) return null;

  final nearest = levels.first;
  final sep = _reSeparator.firstMatch(nearest);
  if (sep != null && sep.start > 0) {
    final candidate = _stripTags(nearest.substring(0, sep.start));
    if (candidate.isNotEmpty && !_isGenericFolder(candidate)) return candidate;
  }

  // Ближайший каталог — альбом, исполнитель — уровнем выше; если выше
  // ничего нет — сам ближайший каталог (как в SoulseekSource.extractArtist).
  for (final d in levels.skip(1)) {
    final candidate = _stripTags(d);
    if (candidate.isNotEmpty && !_isGenericFolder(candidate)) return candidate;
  }
  // Выше только свалки/корень шары («Downloads/Rihanna/03 Title.mp3») —
  // ближайший каталог и есть исполнитель.
  final candidate = _stripTags(nearest);
  return candidate.isNotEmpty && !_isGenericFolder(candidate)
      ? candidate
      : null;
}

final _reSeparator = RegExp(r'\s+[-–—]\s+');

final _reStartsWithDigit = RegExp(r'^\d');

final _reDiscFolder =
    RegExp(r'^(?:cd|disc|disk|диск)\s*\d+$', caseSensitive: false);

/// Номер трека в начале: «03 Title», «10. Title», «2-03 Title»,
/// «11.24 Title», «07) Title». Число без ведущего нуля и без разделителя
/// не трогаем — это бывает частью названия («7 Rings», «21 Guns»).
final _reLeadingTrackNumber = RegExp(
  r'^(?:\d{1,2}[-.]\d{1,3}\s+|\d{1,3}\s*[.)\]]\s*|0\d{1,2}\s+)',
);

/// Сегмент целиком — номер трека («04», «06.», «2-03») или год («2009»).
final _reNumberSegment = RegExp(r'^(?:\d{1,3}[.)]?|\d{1,2}[-.]\d{1,3})$');

const _genericFolders = {
  'music',
  'my music',
  'mp3',
  'flac',
  'lossless',
  'albums',
  'full albums',
  'singles',
  'downloads',
  'complete',
  'shared',
  'share',
  'soulseek',
  'soulseek downloads',
  'slsk',
  'discography',
  'various',
  'various artists',
  'va',
  'new folder',
  'unknown',
  'unknown artist',
  'музыка',
};

String _removeExtension(String name) {
  final dot = name.lastIndexOf('.');
  // Только короткое расширение: «11.24 Paparazzi» — не расширение.
  return dot > 0 && name.length - dot <= 5 ? name.substring(0, dot) : name;
}

bool _isNoiseSegment(String s) =>
    s.isEmpty || _reNumberSegment.hasMatch(s) || _stripTags(s).isEmpty;

String _stripTrackNumber(String s) =>
    s.replaceFirst(_reLeadingTrackNumber, '').trim();

/// Убирает теги «(2009)», «[FLAC]», «[16bit]» и т.п.
String _stripTags(String s) => s
    .replaceAll(RegExp(r'\[[^\]]*\]'), '')
    .replaceAll(RegExp(r'\((?:19|20)\d\d\)'), '')
    .trim();

/// Папка-свалка, корень шары Soulseek («@@abcde») или диск («C:»).
bool _isGenericFolder(String name) =>
    _genericFolders.contains(name.toLowerCase()) ||
    name.startsWith('@@') ||
    _reDriveLetter.hasMatch(name);

final _reDriveLetter = RegExp(r'^[A-Za-z]:$');
