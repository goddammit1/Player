import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';

import '../../../core/artwork_helper.dart';
import '../../../models/track.dart';
import '../../../sources/soulseek_source.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_settings_sheet.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  LIST TRACK TILE
// ═══════════════════════════════════════════════════════════════════════════

class SearchTrackTileList extends StatelessWidget {
  const SearchTrackTileList({
    super.key,
    required this.track,
    required this.isPlaying,
    required this.onTap,
    this.duration,
    required this.colors,
  });

  final Track track;
  final bool isPlaying;
  final VoidCallback onTap;
  final String? duration;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isPlaying ? colors.elevatedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => showTrackSettingsSheet(context, track: track),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Artwork(
                      url: track.artworkUrl,
                      trackId: track.id,
                      size: 54,
                      aspectRatio: artAspectRatio(track),
                      borderRadius: 10,
                    ),
                    if (isPlaying)
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.equalizer_rounded,
                          color: colors.textPrimary,
                          size: 22,
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
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                      // Quality badge / Soulseek icon for Soulseek tracks
                      if (track.sourceId == SoulseekSource.sourceId)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _QualityBadge(
                            track: track,
                            colors: colors,
                          ),
                        ),
                    ],
                  ),
                ),
                if (duration != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    duration!,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GRID TRACK TILE (с поддержкой кастомных обложек)
// ═══════════════════════════════════════════════════════════════════════════

class SearchTrackTileGrid extends StatefulWidget {
  const SearchTrackTileGrid({
    super.key,
    required this.track,
    required this.isPlaying,
    required this.onTap,
    required this.colors,
  });

  final Track track;
  final bool isPlaying;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  State<SearchTrackTileGrid> createState() => _SearchTrackTileGridState();
}

class _SearchTrackTileGridState extends State<SearchTrackTileGrid> {
  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final colors = widget.colors;
    final duration = track.duration != null
        ? _formatDuration(track.duration!)
        : null;

    // 1. Проверяем наличие локальной кастомной обложки по track.id
    final customPath = ArtworkHelper.getCustomArtworkSync(track.id);
    final effectiveUrl = customPath ?? track.artworkUrl;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cellPx = (((MediaQuery.of(context).size.width - 40) / 2) * dpr)
        .round();

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: () => showTrackSettingsSheet(context, track: track),
      child: SizedBox(
        width: 160,
        height: 160,
        child: Stack(
          children: [
            // === ОСНОВНАЯ ОБЛОЖКА ===
            ClipSmoothRect(
              radius: SmoothBorderRadius(
                cornerRadius: 40,
                cornerSmoothing: 1.0,
              ),
              child: SizedBox(
                width: 160,
                height: 160,
                child: effectiveUrl != null && effectiveUrl.isNotEmpty
                    ? _SearchTileImage(
                        url: effectiveUrl,
                        memCacheWidth: cellPx,
                        colors: colors,
                      )
                    : Container(
                        color: colors.elevated,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: colors.textTertiary,
                          size: 32,
                        ),
                      ),
              ),
            ),

            // === БЛЮР-ФОН ПОД ОБЛОЖКОЙ ===
            if (effectiveUrl != null && effectiveUrl.isNotEmpty)
              ClipSmoothRect(
                radius: SmoothBorderRadius(
                  cornerRadius: 40,
                  cornerSmoothing: 1.0,
                ),
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0xFF000000),
                      ],
                      stops: [0.0, 0.4, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: SizedBox(
                      width: 160,
                      height: 160,
                      child: _SearchTileImage(
                        url: effectiveUrl,
                        memCacheWidth: cellPx ~/ 4,
                        colors: colors,
                      ),
                    ),
                  ),
                ),
              ),

            // === ГРАДИЕНТ И ТЕНЬ ===
            ClipSmoothRect(
              radius: SmoothBorderRadius(
                cornerRadius: 40,
                cornerSmoothing: 1.0,
              ),
              child: Container(
                width: 160,
                height: 160,
                decoration: const BoxDecoration(
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

            if (widget.isPlaying)
              ClipSmoothRect(
                radius: SmoothBorderRadius(
                  cornerRadius: 40,
                  cornerSmoothing: 1.0,
                ),
                child: Container(
                  width: 160,
                  height: 160,
                  color: Colors.black.withValues(alpha: 0.3),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.equalizer_rounded,
                    color: colors.textPrimary,
                    size: 28,
                  ),
                ),
              ),

            // === QUALITY BADGE for Soulseek tracks ===
            if (track.sourceId == SoulseekSource.sourceId &&
                track.qualityLabel != null &&
                track.qualityLabel!.isNotEmpty)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.hub_rounded,
                        size: 9,
                        color: (track.qualityLabel!.contains('FLAC') ||
                                track.qualityLabel!.contains('WAV') ||
                                track.qualityLabel!.contains('ALAC'))
                            ? Colors.greenAccent
                            : Colors.white,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        track.qualityLabel!,
                        style: TextStyle(
                          color: (track.qualityLabel!.contains('FLAC') ||
                                  track.qualityLabel!.contains('WAV') ||
                                  track.qualityLabel!.contains('ALAC'))
                              ? Colors.greenAccent
                              : Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    showAddToPlaylistSheet(context, track);
                  },
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.textPrimary.withValues(alpha: 0.9),
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 16,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              left: 16,
              bottom: 24,
              right: duration != null ? 48 : 16,
              child: Text(
                track.title,
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
              bottom: 12,
              right: duration != null ? 48 : 16,
              child: Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ),

            if (duration != null)
              Positioned(
                right: 16,
                bottom: 18,
                child: Text(
                  duration,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Хелпер для отрисовки локальных (File) и сетевых (URL) обложек в плитках
/// сетки.
class _SearchTileImage extends StatelessWidget {
  const _SearchTileImage({
    required this.url,
    required this.memCacheWidth,
    required this.colors,
  });

  final String url;
  final int memCacheWidth;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final isLocalFile = url.startsWith('/') || url.startsWith('file://');
    final filePath = url.startsWith('file://')
        ? Uri.parse(url).toFilePath()
        : url;

    if (isLocalFile) {
      final file = File(filePath);
      return Image.file(
        file,
        key: ValueKey(
          '${filePath}_${file.existsSync() ? file.lastModifiedSync().millisecondsSinceEpoch : 0}',
        ),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(color: colors.elevated),
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: memCacheWidth,
      placeholder: (_, _) => Container(color: colors.elevated),
      errorWidget: (_, _, _) => Container(
        color: colors.elevated,
        child: Icon(
          Icons.music_note_rounded,
          color: colors.textTertiary,
          size: 32,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// QUALITY BADGE — бейдж качества для Soulseek-треков
// ═══════════════════════════════════════════════════════════════════════════

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.track, required this.colors});

  final Track track;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final label = track.qualityLabel;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    final peerCount = (track.extra['peerCount'] as int?) ?? 1;

    // Цвет бейджа: lossless → зелёный, high quality → акцент, иначе — серый
    final isLossless = label.contains('FLAC') ||
        label.contains('WAV') ||
        label.contains('ALAC');
    final isHighQuality = label.contains('320') ||
        label.contains('256') ||
        label.contains('V0');

    final badgeColor = isLossless
        ? Colors.greenAccent
        : isHighQuality
            ? colors.accent as Color
            : colors.textTertiary as Color;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Soulseek icon
        Icon(
          Icons.hub_rounded,
          size: 11,
          color: badgeColor.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 4),
        // Quality label
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: badgeColor.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: badgeColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        // Сколько полностью одинаковых файлов от разных пиров свёрнуто
        // в этот трек (SoulseekSource: extra.peerCount).
        if (peerCount > 1) ...[
          const SizedBox(width: 4),
          Text(
            '×$peerCount',
            style: TextStyle(
              color: badgeColor.withValues(alpha: 0.8),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}