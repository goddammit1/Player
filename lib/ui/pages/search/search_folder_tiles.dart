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
        isFolder = false;

  SearchEntry.folder(this.tracks) : isFolder = true;

  final List<Track> tracks;
  final bool isFolder;
}

/// Сворачивает треки папок в [SearchEntry.folder] на месте первого трека
/// папки; остальные треки — по одному.
List<SearchEntry> groupSearchEntries(List<Track> tracks) {
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
  return entries;
}

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
    required this.isPlaying,
    required this.onPlay,
    required this.colors,
  });

  final List<Track> tracks;

  /// Играет один из треков папки.
  final bool isPlaying;

  /// Воспроизвести папку с начала.
  final VoidCallback onPlay;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final info = SoulseekFolderInfo.of(tracks);
    final first = tracks.first;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isPlaying ? colors.elevatedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showSoulseekFolderSheet(context, tracks),
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
                        info.name,
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
                        info.artist,
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
                  tooltip: 'Play folder',
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
    required this.isPlaying,
    required this.colors,
  });

  final List<Track> tracks;
  final bool isPlaying;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final info = SoulseekFolderInfo.of(tracks);
    final first = tracks.first;
    final radius = SmoothBorderRadius(cornerRadius: 40, cornerSmoothing: 1.0);
    return GestureDetector(
      onTap: () => showSoulseekFolderSheet(context, tracks),
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
                    info.name,
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
                    info.artist,
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
