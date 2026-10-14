// lib/ui/desktop/now_playing_panel.dart
//
// Вкладка «Track» правой панели — десктопная замена полноэкранного
// PlayerPage без изменения раскладки shell: большая обложка (по наведению —
// смена / сброс), метаданные, действия трека инлайн. Фон — PlayerBackground,
// поэтому тема Blur даёт эффект и на десктопе.

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart' show artAspectRatio;
import '../../core/artwork_image_provider.dart';
import '../../core/cover_actions.dart';
import '../../core/player_conversions.dart';
import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../pages/player/player_background.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/track_settings_sheet.dart';
import 'design/dimens.dart';

/// «SOURCE • QUALITY» для играющего трека; пустая строка — данных нет
/// (никаких выдуманных значений по умолчанию).
String desktopTrackMeta(String? sourceId, String? qualityLabel) {
  final parts = <String>[];
  if (sourceId != null && sourceId.isNotEmpty) {
    parts.add(
      (SourceRegistry.instance.get(sourceId)?.displayName ?? sourceId)
          .toUpperCase(),
    );
  }
  if (qualityLabel != null && qualityLabel.isNotEmpty) {
    parts.add(qualityLabel.toUpperCase());
  }
  return parts.join(' • ');
}

class NowPlayingPanel extends ConsumerStatefulWidget {
  const NowPlayingPanel({super.key});

  @override
  ConsumerState<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends ConsumerState<NowPlayingPanel> {
  String? _artworkUrl;
  ImageProvider? _artwork;

  /// Источник обложки для Blur-фона, кэш по URL (как в PlayerContent):
  /// build идёт на каждом кадре перехода палитры.
  ImageProvider? _artworkFor(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url != _artworkUrl || _artwork == null) {
      _artworkUrl = url;
      _artwork = artworkImageProvider(url);
    }
    return _artwork;
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    final colors = ref.watch(animatedPaletteProvider);
    final background = ref.watch(
      appThemeModeProvider.select((mode) => mode.playerBackground),
    );

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      initialData: player.mediaItemValue,
      builder: (context, itemSnap) {
        final item = itemSnap.data;
        if (item != null) {
          return _withBackground(
            background,
            colors,
            item.artUri?.toString(),
            _NowPlayingContent(
              track: PlayerConversions.trackFromExtras(item),
              artworkUrl: item.artUri?.toString(),
              player: player,
              colors: colors,
              translucentTiles: background != PlayerBackgroundStyle.gradient,
            ),
          );
        }
        // Сессия восстановлена, но трек ещё не запускали: показываем
        // текущий элемент очереди, play в баре продолжит с него.
        return StreamBuilder<List<Track>>(
          stream: player.trackQueueStream,
          initialData: player.trackQueue,
          builder: (context, queueSnap) {
            final queue = queueSnap.data ?? const <Track>[];
            final index = player.currentIndex;
            if (index < 0 || index >= queue.length) {
              return Center(
                child: Text(
                  'No track',
                  style: TextStyle(color: colors.textTertiary, fontSize: 13),
                ),
              );
            }
            final track = queue[index];
            return _withBackground(
              background,
              colors,
              track.artworkUrl,
              _NowPlayingContent(
                track: track,
                artworkUrl: track.artworkUrl,
                player: player,
                colors: colors,
                translucentTiles: background != PlayerBackgroundStyle.gradient,
              ),
            );
          },
        );
      },
    );
  }

  /// Gradient-тема оставляет панель обычной (цвет `elevated`, как у
  /// остальных островов); Blur рисует фон плеера.
  Widget _withBackground(
    PlayerBackgroundStyle style,
    AppColors colors,
    String? artworkUrl,
    Widget child,
  ) {
    if (style == PlayerBackgroundStyle.gradient) return child;
    return PlayerBackground(
      style: style,
      colors: colors,
      artwork: style == PlayerBackgroundStyle.blur
          ? _artworkFor(artworkUrl)
          : null,
      child: child,
    );
  }
}

class _NowPlayingContent extends StatelessWidget {
  const _NowPlayingContent({
    required this.track,
    required this.artworkUrl,
    required this.player,
    required this.colors,
    required this.translucentTiles,
  });

  final Track track;
  final String? artworkUrl;
  final PlayerServiceInterface player;
  final AppColors colors;

  /// Поверх Blur плитки полупрозрачные, чтобы фон читался.
  final bool translucentTiles;

  @override
  Widget build(BuildContext context) {
    final meta = desktopTrackMeta(track.sourceId, track.qualityLabel);
    final tileColor = translucentTiles
        ? colors.background.withValues(alpha: 0.45)
        : colors.background;

    return LayoutBuilder(
      builder: (context, c) {
        const pad = 20.0;
        final coverSize = (c.maxWidth - pad * 2).clamp(0.0, 420.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: _HoverCover(
                  key: ValueKey('cover_${track.id}'),
                  track: track,
                  artworkUrl: artworkUrl,
                  size: coverSize,
                  player: player,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ],
              const SizedBox(height: 20),
              Material(
                color: tileColor,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  key: const Key('now_playing_add_to_playlist'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => showAddToPlaylistSheet(context, track),
                  child: SizedBox(
                    height: 50,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            color: colors.textPrimary,
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Text(
                            'Add to playlist',
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
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: tileColor,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: BoostSlider(
                    key: const Key('now_playing_boost'),
                    player: player,
                    colors: colors,
                    label: 'Boost',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Download / Sleep timer / Details / Open folder. Ключ по
              // треку: кэш-статус читается при создании группы.
              TrackActionsGroup(
                key: ValueKey('actions_${track.globalId}'),
                track: track,
                colors: colors,
                player: player,
                insideSheet: false,
                tileColor: tileColor,
                separatorColor: Colors.transparent,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Обложка с оверлеем «Change cover» / «Reset» по наведению мыши.
class _HoverCover extends StatefulWidget {
  const _HoverCover({
    super.key,
    required this.track,
    required this.artworkUrl,
    required this.size,
    required this.player,
  });

  final Track track;
  final String? artworkUrl;
  final double size;
  final PlayerServiceInterface player;

  @override
  State<_HoverCover> createState() => _HoverCoverState();
}

class _HoverCoverState extends State<_HoverCover> {
  bool _hovered = false;

  Future<void> _change() async {
    await CoverActions.change(widget.player, widget.track.id);
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    await CoverActions.reset(widget.player, widget.track.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasCustom = CoverActions.hasCustom(widget.track.id);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Dimens.radiusCard - 8),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(
                url: widget.artworkUrl,
                trackId: widget.track.id,
                artist: widget.track.artist,
                title: widget.track.title,
                size: widget.size,
                borderRadius: 0,
                memCacheSize: 600,
                aspectRatio: artAspectRatio(widget.track),
              ),
              AnimatedOpacity(
                opacity: _hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: IgnorePointer(
                  ignoring: !_hovered,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.55),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _CoverButton(
                            key: const Key('now_playing_change_cover'),
                            icon: Icons.image_outlined,
                            label: 'Change cover',
                            onTap: _change,
                          ),
                          if (hasCustom) ...[
                            const SizedBox(height: 8),
                            _CoverButton(
                              key: const Key('now_playing_reset_cover'),
                              icon: Icons.restore_rounded,
                              label: 'Reset',
                              onTap: _reset,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverButton extends StatelessWidget {
  const _CoverButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Dimens.radiusPill),
      child: InkWell(
        borderRadius: BorderRadius.circular(Dimens.radiusPill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
