import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/player_service.dart';
import '../../core/providers.dart';
import '../../models/track.dart';
import 'add_to_playlist_sheet.dart';
import '../../sources/source_registry.dart';
import 'artwork.dart';
import 'track_details_sheet.dart';
import '../../core/youtube_cache.dart';

// =============================================================================
// PUBLIC API
// =============================================================================

Future<void> showTrackSettingsSheet(
  BuildContext context, {
  required Track track,
  MediaItem? currentMediaItem,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    useRootNavigator: true,
    builder: (sheetCtx) => _TrackSettingsSheet(
      track: track,
      currentMediaItem: currentMediaItem,
    ),
  );
}

// =============================================================================
// SHEET
// =============================================================================

class _TrackSettingsSheet extends ConsumerStatefulWidget {
  const _TrackSettingsSheet({
    required this.track,
    this.currentMediaItem,
  });

  final Track track;
  final MediaItem? currentMediaItem;

  @override
  ConsumerState<_TrackSettingsSheet> createState() =>
      _TrackSettingsSheetState();
}

class _TrackSettingsSheetState extends ConsumerState<_TrackSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final player = ref.watch(playerServiceProvider);
    final t = widget.track;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Drag handle ──
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Track header ──
            _TrackHeader(
              track: t,
              mediaItem: widget.currentMediaItem,
              colors: colors,
            ),

            const SizedBox(height: 12),

            // ── Action buttons ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.playlist_add_rounded,
                      label: 'Add to playlist',
                      onTap: () => _showAddToPlaylist(context, t),
                      colors: colors,
                      position: _ButtonPosition.left,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.queue_play_next_rounded,
                      label: 'Play Next',
                      onTap: () => _addToQueueNext(context, player, t),
                      colors: colors,
                      position: _ButtonPosition.right,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── Volume slider ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _VolumeSlider(
                player: player,
                colors: colors,
              ),
            ),

            const SizedBox(height: 20),

            // ── Settings label ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Settings',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            const SizedBox(height: 10),

            // ── Settings group (Download + Details) ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _SettingsGroup(
                track: t,
                colors: colors,
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _showAddToPlaylist(BuildContext ctx, Track track) {
    showAddToPlaylistSheet(ctx, track);
  }

  void _addToQueueNext(BuildContext ctx, PlayerService player, Track track) {
    player.insertToQueue(track);
    Navigator.of(ctx).pop();
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          '"${track.title}" added to queue',
          style: TextStyle(color: ref.read(animatedPaletteProvider).textPrimary),
        ),
        backgroundColor: ref.read(animatedPaletteProvider).elevated,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// =============================================================================
// TRACK HEADER
// =============================================================================

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({
    required this.track,
    required this.mediaItem,
    required this.colors,
  });

  final Track track;
  final MediaItem? mediaItem;
  final AppColors colors;

  String get _durationText {
    final d = mediaItem?.duration ?? track.duration;
    if (d == null) return '--:--';
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Artwork(
            url: track.artworkUrl,
            size: 56,
            borderRadius: 12,
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
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _durationText,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ACTION BUTTON
// =============================================================================

enum _ButtonPosition { left, right }

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.colors,
    this.position = _ButtonPosition.left,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppColors colors;
  final _ButtonPosition position;

  @override
  Widget build(BuildContext context) {
    final borderRadius = position == _ButtonPosition.left
        ? const BorderRadius.only(
            topLeft: Radius.circular(32),
            bottomLeft: Radius.circular(32),
            topRight: Radius.circular(5),
            bottomRight: Radius.circular(5),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(5),
            bottomLeft: Radius.circular(5),
            topRight: Radius.circular(32),
            bottomRight: Radius.circular(32),
          );

    return Material(
      color: colors.elevated,
      borderRadius: borderRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: colors.textPrimary, size: 24),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// VOLUME SLIDER
// =============================================================================

class _VolumeSlider extends ConsumerStatefulWidget {
  const _VolumeSlider({required this.player, required this.colors});

  final PlayerService player;
  final AppColors colors;

  @override
  ConsumerState<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends ConsumerState<_VolumeSlider>
    with SingleTickerProviderStateMixin {
  double? _dragFraction;

  late final AnimationController _thumbAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 50),
    value: 0,
  );

  @override
  void dispose() {
    _thumbAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Volume',
              style: TextStyle(
                color: widget.colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              _labelText,
              style: TextStyle(
                color: widget.colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (_, c) {
            final width = c.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _thumbAnim.forward(),
              onHorizontalDragUpdate: (d) {
                final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
                setState(() => _dragFraction = frac);
                _applyVolumeAndGain(frac);
              },
              onHorizontalDragEnd: (_) {
                _thumbAnim.reverse();
                setState(() => _dragFraction = null);
              },
              onTapDown: (_) => _thumbAnim.forward(),
              onTapUp: (d) {
                _thumbAnim.reverse();
                final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
                _applyVolumeAndGain(frac);
                setState(() => _dragFraction = null);
              },
              onTapCancel: () {
                _thumbAnim.reverse();
                setState(() => _dragFraction = null);
              },
              child: CustomPaint(
                size: const Size(double.infinity, 40),
                painter: _VolumePainter(
                  fraction: _currentFraction,
                  thumbAnim: _thumbAnim,
                  colors: widget.colors,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// Текущая позиция слайдера (0.0–1.0).
  /// 0.0–0.5 → volume 0–100%, gain 0 dB
  /// 0.5–1.0 → volume 100%, gain 0–+6 dB (UI: 100–200%)
  double get _currentFraction {
    if (_dragFraction != null) return _dragFraction!;
    final vol = widget.player.rawPlayer.volume;
    final gain = widget.player.gainDb;
    if (gain > 0) {
      // gain 0..6 dB maps to fraction 0.5..1.0
      return (0.5 + gain / 12.0).clamp(0.5, 1.0);
    }
    return (vol * 0.5).clamp(0.0, 0.5);
  }

  /// Label: 0% → 100% → 200%
  String get _labelText {
    final pct = (_currentFraction * 2 * 100).round();
    return '$pct%';
  }

  /// Применяет volume/gain.
  /// fraction 0.0–0.5: volume 0–100%
  /// fraction 0.5–1.0: volume 100%, gain 0–+6 dB
  Future<void> _applyVolumeAndGain(double fraction) async {
    if (fraction <= 0.5) {
      final volume = (fraction * 2.0).clamp(0.0, 1.0);
      await widget.player.setVolumeAndGain(volume, 0.0);
    } else {
      final gainDb = ((fraction - 0.5) * 2.0 * 6.0).clamp(0.0, 6.0);
      await widget.player.setVolumeAndGain(1.0, gainDb);
    }
  }
}

class _VolumePainter extends CustomPainter {
  _VolumePainter({
    required this.fraction,
    required this.thumbAnim,
    required this.colors,
  }) : super(repaint: thumbAnim);

  final double fraction;
  final Animation<double> thumbAnim;
  final AppColors colors;

  static const _trackHeight = 50.0;
  static const _thumbWidthNormal = 10.0;
  static const _thumbWidthDragging = 6.0;
  static const _thumbHeightNormal = 56.0;
  static const _thumbHeightDragging = 56.0;
  static const _thumbRadius = 4.0;
  static const _gapNormal = 4.0;
  static const _gapDragging = 4.0;
  static const _margin = 0.0;

  static const _iconWidth = 16.0;
  static const _iconPadding = 16.0;
  static const _iconTotalWidth = _iconWidth + _iconPadding * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final totalWidth = size.width - _margin * 2;
    final filledW = totalWidth * fraction.clamp(0.0, 1.0);

    final double t = thumbAnim.value;

    final double thumbWidth =
        _thumbWidthNormal + (_thumbWidthDragging - _thumbWidthNormal) * t;
    final double thumbHeight =
        _thumbHeightNormal + (_thumbHeightDragging - _thumbHeightNormal) * t;
    final double gap = _gapNormal + (_gapDragging - _gapNormal) * t;

    final double thumbCornerRadius = 2 + 2 * t;

    final double thumbX = _margin + filledW - thumbWidth / 2;
    final double clampedThumbX =
        thumbX.clamp(_margin, _margin + totalWidth - thumbWidth);

    final double iconBaseX = _margin + _iconPadding;
    final double iconShiftThreshold = _iconTotalWidth;
    final double iconX = clampedThumbX < iconShiftThreshold
        ? clampedThumbX + thumbWidth / 2 + gap + _iconPadding
        : iconBaseX;

    if (clampedThumbX + thumbWidth + gap < _margin + totalWidth) {
      final double trackStart = clampedThumbX + thumbWidth + gap;
      final double trackWidth = (_margin + totalWidth) - trackStart;

      final trackRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
            trackStart, centerY - _trackHeight / 2, trackWidth, _trackHeight),
        topLeft: Radius.circular(thumbCornerRadius),
        topRight: const Radius.circular(5),
        bottomLeft: Radius.circular(thumbCornerRadius),
        bottomRight: const Radius.circular(5),
      );
      final trackPaint = Paint()
        ..color = colors.elevated.withValues(alpha: 0.5);
      canvas.drawRRect(trackRect, trackPaint);
    }

    if (clampedThumbX > _margin + gap) {
      final double filledWidth = clampedThumbX - gap - _margin;

      final filledRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
            _margin, centerY - _trackHeight / 2, filledWidth, _trackHeight),
        topLeft: const Radius.circular(5),
        topRight: Radius.circular(thumbCornerRadius),
        bottomLeft: const Radius.circular(5),
        bottomRight: Radius.circular(thumbCornerRadius),
      );
      final filledPaint = Paint()..color = colors.elevatedHi;
      canvas.drawRRect(filledRect, filledPaint);
    }

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
          clampedThumbX, centerY - thumbHeight / 2, thumbWidth, thumbHeight),
      const Radius.circular(_thumbRadius),
    );
    final thumbPaint = Paint()..color = colors.elevatedHi;
    canvas.drawRRect(thumbRect, thumbPaint);

    _drawVolumeIcon(canvas, size, fraction, colors, iconX);
  }

  void _drawVolumeIcon(
    Canvas canvas,
    Size size,
    double fraction,
    AppColors colors,
    double iconX,
  ) {
    final IconData iconData;
    if (fraction <= 0.005) {
      iconData = Icons.volume_off_rounded;
    } else if (fraction < 0.25) {
      iconData = Icons.volume_mute_rounded;
    } else if (fraction < 0.5) {
      iconData = Icons.volume_down_rounded;
    } else {
      iconData = Icons.volume_up_rounded;
    }

    final iconStr = String.fromCharCode(iconData.codePoint);
    final textPainter = TextPainter(
      text: TextSpan(
        text: iconStr,
        style: TextStyle(
          fontFamily: iconData.fontFamily,
          fontSize: 20,
          color: colors.textPrimary,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final iconY = (size.height - textPainter.height) / 2;
    textPainter.paint(canvas, Offset(iconX, iconY));
  }

  @override
  bool shouldRepaint(_VolumePainter old) {
    return old.fraction != fraction ||
        old.thumbAnim.value != thumbAnim.value ||
        old.colors != colors;
  }
}

// =============================================================================
// SETTINGS GROUP (РЕАЛЬНОЕ КЭШИРОВАНИЕ)
// =============================================================================

class _SettingsGroup extends ConsumerStatefulWidget {
  const _SettingsGroup({required this.track, required this.colors});

  final Track track;
  final AppColors colors;

  @override
  ConsumerState<_SettingsGroup> createState() => _SettingsGroupState();
}

class _SettingsGroupState extends ConsumerState<_SettingsGroup> {
  bool _isCached = false;
  bool _checking = true;
  bool _downloading = false;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  /// Формирует namespaced id так же, как в PlayerService._cacheIdForTrack
  String _cacheId(Track track) {
    switch (track.sourceId) {
      case 'muzmo':
        return 'muzmo_${track.id}';
      case 'soundcloud':
        return 'soundcloud_${track.id}';
      default:
        return track.id;
    }
  }

  Future<void> _checkCache() async {
    setState(() => _checking = true);
    try {
      _isCached = await YoutubeCache.instance.hasFile(_cacheId(widget.track));
    } catch (_) {
      _isCached = false;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = 0.0;
    });

    try {
      // Резолвим прямую ссылку
      final source = SourceRegistry.instance.require(widget.track.sourceId);
      final url = await source.resolveStreamUrl(widget.track);

      // Получаем путь в кэше
      final cacheFile = await YoutubeCache.instance.fileFor(
        _cacheId(widget.track),
        extension: 'mp3',
      );

      // Скачиваем напрямую в кэш-директорию
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

      await dio.download(
        url,
        cacheFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = (received / total).clamp(0.0, 1.0));
          }
        },
      );

      // Обновляем LRU, чтобы эвиктор не удалил свежескачанный трек
      YoutubeCache.instance.touch(_cacheId(widget.track));

      if (mounted) {
        setState(() {
          _isCached = true;
          _downloading = false;
          _progress = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _progress = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: widget.colors.elevated,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _deleteCache() async {
    setState(() => _checking = true);
    try {
      await YoutubeCache.instance.evict(_cacheId(widget.track));
      if (mounted) setState(() => _isCached = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: $e'),
            backgroundColor: widget.colors.elevated,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _showDetails(BuildContext context) {
    showTrackDetailsSheet(context, widget.track);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    final tiles = <_SettingsTileData>[
      _SettingsTileData(
        icon: _isCached ? Icons.download_done_rounded : Icons.download_rounded,
        iconColor: _isCached ? colors.accent : colors.textPrimary,
        title: _isCached ? 'Cached' : 'Download',
        subtitle: _isCached ? 'Available offline' : null,
        trailing: _isCached
            ? Icon(Icons.check_circle_rounded, color: colors.accent, size: 20)
            : null,
        onTap: _isCached ? _deleteCache : _download,
        loading: _checking || _downloading,
        progress: _downloading ? _progress : null,
      ),
      _SettingsTileData(
        icon: Icons.info_outline_rounded,
        title: 'Details',
        onTap: () => _showDetails(context),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            _SettingsTile(
              data: tiles[i],
              position: _tilePosition(i, tiles.length),
              colors: colors,
            ),
            if (i < tiles.length - 1)
              Container(height: 4, color: colors.background),
          ],
        ],
      ),
    );
  }

  _TilePosition _tilePosition(int index, int total) {
    if (total == 1) return _TilePosition.single;
    if (index == 0) return _TilePosition.first;
    if (index == total - 1) return _TilePosition.last;
    return _TilePosition.middle;
  }
}

enum _TilePosition { first, middle, last, single }

class _SettingsTileData {
  const _SettingsTileData({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.loading = false,
    this.progress,
  });

  final IconData icon;
  final String title;
  final Color? iconColor;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool loading;
  final double? progress;
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.data,
    required this.position,
    required this.colors,
  });

  final _SettingsTileData data;
  final _TilePosition position;
  final AppColors colors;

  BorderRadius get _borderRadius {
    const r = Radius.circular(16);
    switch (position) {
      case _TilePosition.single:
        return const BorderRadius.all(r);
      case _TilePosition.first:
        return const BorderRadius.vertical(top: r);
      case _TilePosition.middle:
        return BorderRadius.zero;
      case _TilePosition.last:
        return const BorderRadius.vertical(bottom: r);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (data.loading && data.progress != null) {
      return SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  value: data.progress,
                  strokeWidth: 2,
                  color: colors.elevatedHi,
                  backgroundColor: colors.elevatedVariant,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Downloading… ${((data.progress ?? 0) * 100).round()}%',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (data.loading) {
      return const SizedBox(
        height: 50,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return InkWell(
      onTap: data.onTap,
      borderRadius: _borderRadius,
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                data.icon,
                color: data.iconColor ?? colors.textPrimary,
                size: 22,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      data.title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (data.subtitle != null)
                      Text(
                        data.subtitle!,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (data.trailing != null) data.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}