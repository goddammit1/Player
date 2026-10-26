import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';

import '../../../models/track.dart';
import '../../widgets/artwork.dart';
import '../../widgets/soulseek_folder_sheet.dart';

/// Элемент выдачи поиска: трек или папка Soulseek (треки с общим
/// `extra.folderKey`, см. SoulseekSource) — как карточки папок в Seeker.
class SearchEntry {
  SearchEntry.track(Track track)
      : tracks = [track],
        isFolder = false,
        focus = null;

  SearchEntry.folder(this.tracks, {this.focus}) : isFolder = true;

  final List<Track> tracks;
  final bool isFolder;

  /// Трек папки, который искали ([folderFocusIndex]); null — искали саму
  /// папку (альбом) или совпадение неочевидно.
  final int? focus;

  Track? get focusTrack => focus == null ? null : tracks[focus!];
}

/// Сворачивает треки папок в [SearchEntry.folder] на месте первого трека
/// папки; остальные треки — по одному. [query] — запрос поиска: по нему в
/// папке находится искомый трек ([SearchEntry.focus]).
List<SearchEntry> groupSearchEntries(List<Track> tracks, {String query = ''}) {
  final entries = <SearchEntry>[];
  final folders = <String, List<Track>>{};
  for (final t in tracks) {
    final key = t.extra['folderKey'] as String?;
    if (key == null) {
      entries.add(SearchEntry.track(t));
      continue;
    }
    final known = folders[key];
    if (known != null) {
      known.add(t);
      continue;
    }
    final list = [t];
    folders[key] = list;
    entries.add(SearchEntry.folder(list));
  }
  return [
    for (final e in entries)
      e.isFolder
          ? SearchEntry.folder(e.tracks,
              focus: folderFocusIndex(e.tracks, query))
          : e,
  ];
}

/// Индекс трека [tracks], который искали запросом [query], или null.
///
/// Пир отвечает файлами, у которых слова запроса есть где-то в пути, — если
/// слова названия трека входят и в название папки (заглавный трек альбома),
/// совпадает весь альбом, и без этого карточка играла бы первый трек.
/// Кандидат — трек, все слова названия которого (без скобок «(Live)»,
/// «[Remastered]» и номера) есть в запросе; из нескольких выигрывает более
/// длинное название, затем меньше лишних слов в полном названии.
int? folderFocusIndex(List<Track> tracks, String query) {
  final q = _words(query).toSet();
  if (q.isEmpty) return null;
  int? best;
  var bestScore = 0;
  for (var i = 0; i < tracks.length; i++) {
    final title = tracks[i].title;
    final core = _titleWords(title.replaceAll(_brackets, ' '));
    if (core.isEmpty || !core.every(q.contains)) continue;
    final extra = _titleWords(title).where((w) => !q.contains(w)).length;
    final score = core.length * 100 - extra;
    if (best == null || score > bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return best;
}

final _brackets = RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}');
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _digits = RegExp(r'^\d+$');

List<String> _words(String s) => s
    .toLowerCase()
    .replaceAll('ё', 'е')
    .split(_nonWord)
    .where((w) => w.isNotEmpty)
    .toList();

/// Слова названия без ведущего номера трека («01 Title» → [title]).
List<String> _titleWords(String title) =>
    _words(title).skipWhile(_digits.hasMatch).toList();

/// Заголовки карточки: искомый трек и «исполнитель · папка» или, без
/// [focus], папка и исполнитель.
(String, String) _folderTitles(SoulseekFolderInfo info, Track? focus) =>
    focus == null
        ? (info.name, info.artist)
        : (focus.title, '${info.artist} · ${info.name}');

/// Строка «пользователь · N tracks · FLAC · ×2» под названием папки.
String _folderMeta(SoulseekFolderInfo info, int count) => [
      '$count tracks',
      ?info.qualityLabel,
      if (info.peers > 1) '×${info.peers}',
    ].join(' · ');

// ═══════════════════════════════════════════════════════════════════════════
//  LIST FOLDER TILE
// ═══════════════════════════════════════════════════════════════════════════

class SearchFolderTileList extends StatelessWidget {
  const SearchFolderTileList({
    super.key,
    required this.tracks,
    this.focus,
    required this.isPlaying,
    required this.onPlay,
    required this.colors,
  });

  final List<Track> tracks;

  /// Искомый трек папки ([SearchEntry.focusTrack]).
  final Track? focus;

  /// Играет один из треков папки.
  final bool isPlaying;

  /// Воспроизвести папку — с [focus] или с начала.
  final VoidCallback onPlay;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final info = SoulseekFolderInfo.of(tracks);
    final first = focus ?? tracks.first;
    final (title, subtitle) = _folderTitles(info, focus);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isPlaying ? colors.elevatedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showSoulseekFolderSheet(context, tracks, focus: focus),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Stack(
                  children: [
                    Artwork(
                      url: info.artworkUrl,
                      trackId: first.id,
                      artist: first.artist,
                      title: first.title,
                      size: 54,
                      borderRadius: 10,
                    ),
                    Positioned(
                      right: 3,
                      bottom: 3,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Icon(
                          Icons.folder_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.hub_rounded,
                            size: 11,
                            color: colors.textTertiary,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _folderMeta(info, tracks.length),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onPlay,
                  icon: Icon(
                    Icons.play_circle_fill_rounded,
                    color: colors.textPrimary,
                  ),
                  iconSize: 30,
                  tooltip: focus == null ? 'Play folder' : 'Play',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  GRID FOLDER TILE
// ═══════════════════════════════════════════════════════════════════════════

class SearchFolderTileGrid extends StatelessWidget {
  const SearchFolderTileGrid({
    super.key,
    required this.tracks,
    this.focus,
    required this.isPlaying,
    required this.colors,
  });

  final List<Track> tracks;

  /// Искомый трек папки ([SearchEntry.focusTrack]).
  final Track? focus;
  final bool isPlaying;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final info = SoulseekFolderInfo.of(tracks);
    final first = focus ?? tracks.first;
    final (title, subtitle) = _folderTitles(info, focus);
    final radius = SmoothBorderRadius(cornerRadius: 40, cornerSmoothing: 1.0);
    return GestureDetector(
      onTap: () => showSoulseekFolderSheet(context, tracks, focus: focus),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.maxWidth;
          return ClipSmoothRect(
            radius: radius,
            child: Stack(
              children: [
                Artwork(
                  url: info.artworkUrl,
                  trackId: first.id,
                  artist: first.artist,
                  title: first.title,
                  size: side,
                  borderRadius: 0,
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00161616),
                          Color(0x00161616),
                          Color(0x80161616),
                          Color(0xCC161616),
                        ],
                        stops: [0.0, 0.35, 0.65, 1.0],
                      ),
                    ),
                  ),
                ),
                if (isPlaying)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.equalizer_rounded,
                        color: colors.textPrimary,
                        size: 28,
                      ),
                    ),
                  ),
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.folder_rounded,
                            size: 10,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              _folderMeta(info, tracks.length),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
