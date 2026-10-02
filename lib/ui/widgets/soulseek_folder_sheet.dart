// lib/ui/widgets/soulseek_folder_sheet.dart
//
// Папка пира Soulseek (альбом) — как карточка папки в SeekerAndroid.
//
// Открывается с карточки папки в выдаче или из меню одиночного трека.
// Сразу показывает известные треки (совпавшие с поиском), параллельно
// запрашивает у пира всю папку (SoulseekSource.loadFolder) и, когда она
// пришла, показывает полный список. Тап по треку — очередь из треков папки.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/soulseek_source.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import 'artwork.dart';
import 'track_settings_sheet.dart';

/// Сводка папки для карточки и шапки шторки.
class SoulseekFolderInfo {
  SoulseekFolderInfo._({
    required this.name,
    required this.artist,
    required this.username,
    required this.qualityLabel,
    required this.peers,
    required this.artworkUrl,
  });

  /// Сводка по трекам одной папки ([tracks] не пуст).
  factory SoulseekFolderInfo.of(List<Track> tracks) {
    final first = tracks.first;
    final remote = (first.extra['remoteFilename'] as String?) ?? '';
    final folder = SoulseekSource.folderOf(remote);
    var name = SoulseekSource.leafOf(folder);
    // «CD1» / «Disc 2» сами по себе ничего не говорят — с родительской папкой.
    if (_discFolder.hasMatch(name)) {
      final parent = SoulseekSource.leafOf(SoulseekSource.folderOf(folder));
      if (parent.isNotEmpty) name = '$parent · $name';
    }

    final artistCounts = <String, int>{};
    for (final t in tracks) {
      if (t.artist == 'Unknown') continue;
      artistCounts[t.artist] = (artistCounts[t.artist] ?? 0) + 1;
    }
    final artist = artistCounts.isEmpty
        ? first.artist
        : (artistCounts.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .first
            .key;

    return SoulseekFolderInfo._(
      name: name.isEmpty ? first.title : name,
      artist: artist,
      username: (first.extra['peerUsername'] as String?) ?? '',
      qualityLabel: first.qualityLabel,
      peers: (first.extra['folderPeers'] as int?) ?? 1,
      artworkUrl: tracks
          .map((t) => t.artworkUrl)
          .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null),
    );
  }

  static final _discFolder =
      RegExp(r'^(cd|disc|disk)\s*\d+', caseSensitive: false);

  final String name;
  final String artist;
  final String username;
  final String? qualityLabel;

  /// Сколько пиров прислали такую же папку (`extra.folderPeers`).
  final int peers;
  final String? artworkUrl;
}

/// Показывает шторку папки, в которой лежат [tracks] (треки одного пира и
/// одного каталога).
Future<void> showSoulseekFolderSheet(BuildContext context, List<Track> tracks) {
  if (tracks.isEmpty) return Future.value();
  if (isDesktop) {
    return showDesktopModalSheet(
      context: context,
      builder: (_) => SoulseekFolderSheet(tracks: tracks),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => SoulseekFolderSheet(tracks: tracks),
  );
}

class SoulseekFolderSheet extends ConsumerStatefulWidget {
  const SoulseekFolderSheet({super.key, required this.tracks});

  /// Известные треки папки (из выдачи поиска).
  final List<Track> tracks;

  @override
  ConsumerState<SoulseekFolderSheet> createState() =>
      _SoulseekFolderSheetState();
}

class _SoulseekFolderSheetState extends ConsumerState<SoulseekFolderSheet> {
  late List<Track> _tracks = widget.tracks;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadFolder();
  }

  Future<void> _loadFolder() async {
    final source = SourceRegistry.instance.get(SoulseekSource.sourceId);
    if (source is! SoulseekSource) return;
    setState(() => _loading = true);
    try {
      final full = await source.loadFolder(widget.tracks);
      if (!mounted) return;
      setState(() {
        _tracks = full;
        _loading = false;
      });
    } catch (_) {
      // Пир офлайн / не принял соединение — остаются совпавшие файлы.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _play(int index) {
    ref.read(playerServiceProvider).setQueue(List.of(_tracks), startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final media = MediaQuery.of(context);
    final info = SoulseekFolderInfo.of(_tracks);

    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          _buildHeader(info, colors),
          _buildActions(colors),
          const Divider(height: 1),
          Flexible(child: _buildList(colors, media.padding.bottom)),
        ],
      ),
    );
  }

  Widget _buildHeader(SoulseekFolderInfo info, dynamic colors) {
    final first = _tracks.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
      child: Row(
        children: [
          Artwork(
            url: info.artworkUrl,
            trackId: first.id,
            artist: first.artist,
            title: first.title,
            size: 72,
            borderRadius: 12,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  info.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    info.username,
                    '${_tracks.length} tracks',
                    ?info.qualityLabel,
                    if (info.peers > 1) '×${info.peers} peers',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.close_rounded, color: colors.textSecondary),
            iconSize: 22,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildActions(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: () => _play(0),
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.background,
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
          ),
          const SizedBox(width: 14),
          if (_loading) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textTertiary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              _loading
                  ? 'Loading full folder…'
                  : _failed
                      ? 'Peer unavailable — matched files only'
                      : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textTertiary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(dynamic colors, double bottomInset) {
    final player = ref.read(playerServiceProvider);
    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final currentId = snap.data?.id;
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(8, 6, 8, bottomInset + 12),
          itemCount: _tracks.length,
          itemBuilder: (context, i) {
            final t = _tracks[i];
            final playing = currentId != null && currentId == t.globalId;
            final duration = t.duration;
            return Material(
              color: playing ? colors.elevatedHi : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _play(i),
                onLongPress: () => showTrackSettingsSheet(context, track: t),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: playing
                            ? Icon(Icons.equalizer_rounded,
                                size: 18, color: colors.accent)
                            : Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: colors.textTertiary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (t.qualityLabel != null &&
                                t.qualityLabel!.isNotEmpty)
                              Text(
                                t.qualityLabel!,
                                style: TextStyle(
                                  color: colors.textTertiary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (duration != null)
                        Text(
                          '${duration.inMinutes}:'
                          '${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
