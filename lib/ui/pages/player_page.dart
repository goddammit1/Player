// lib/ui/pages/player_page.dart

import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem, PlaybackState;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/artwork_image_provider.dart';
import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/queue_sheet.dart';

import 'player/player_background.dart';
import 'player/player_bottom_actions.dart';
import 'player/player_controls.dart';
import 'player/player_interactive_artwork.dart';
import 'player/player_progress_bar.dart';
import 'player/player_title_scroller.dart';

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF000000),
      body: PlayerContent(),
    );
  }
}

/// Содержимое плеера.
class PlayerContent extends ConsumerStatefulWidget {
  const PlayerContent({super.key, this.onClose, this.active = true});

  final VoidCallback? onClose;
  final bool active;

  @override
  ConsumerState<PlayerContent> createState() => _PlayerContentState();
}

class _PlayerContentState extends ConsumerState<PlayerContent>
    with TickerProviderStateMixin {
  late final QueueSheetController _queueCtrl;

  String? _cachedArtworkId;
  ImageProvider? _cachedArtwork;

  // --- Константы раскладки ---
  static const double _wideBreakpoint = 1000;
  static const double _desktopMaxWidth = 600;
  static const double _mobileArtMaxSize = 420;
  static const double _artHeightFactor = 0.85;
  static const double _artPreferredMax = 480;
  static const double _artMinSize = 280;
  static const double _artMaxSize = 520;
  static const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(24, 8, 24, 28);

   // --- Радиусы и тень обложки ---
  /// Базовый радиус обложки при воспроизведении (исходный размер).
  /// ⚠️ Подгоните под значение, которое реально используется внутри
  /// PlayerInteractiveArtwork / Artwork, чтобы вид совпадал.
  static const double _artworkRadiusPlaying = 15;
  /// Радиус в уменьшенной версии (на паузе) — углы скруглены сильнее.
  static const double _artworkRadiusPaused = 30;

  static const double _artworkShadowBlur = 10;
  static const double _artworkShadowSpread = 0;
  static const double _artworkShadowOffsetY = 0;
  static const double _artworkShadowOpacity = 0.15;

  static const double _vSpaceLarge = 30;
  static const double _vSpaceMedium = 20;
  static const double _vSpaceSmall = 15;

  static const double _hArtToControls = 56;
  static const double _hTitleToArtist = 4;
  static const double _hArtistToControls = 32;
  static const double _hControlsToProgress = 20;
  static const double _hProgressToActions = 24;

  // --- Анимация обложки ---
  /// Масштаб обложки на паузе (уменьшена на 7%).
  static const double _artworkPausedScale = 0.93;
  /// Масштаб при воспроизведении (исходный размер).
  static const double _artworkPlayingScale = 1.0;
  static const Duration _artworkScaleDuration = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _queueCtrl = QueueSheetController(vsync: this);
  }

  @override
  void dispose() {
    _queueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Text(
              'Ошибка загрузки: ${snap.error}',
              style: const TextStyle(color: Colors.white),
            ),
          );
        }

        final item = snap.data;

        return Consumer(
          builder: (context, ref, _) {
            final colors = ref.watch(animatedPaletteProvider);
            final background = ref.watch(
              appThemeModeProvider.select((mode) => mode.playerBackground),
            );

            return PlayerBackground(
              style: background,
              colors: colors,
              artwork: background == PlayerBackgroundStyle.blur
                  ? _artworkFor(item)
                  : null,
              animate: widget.active,
              child: SafeArea(
                child: item == null
                    ? Center(
                        child: Text(
                          'No track',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      )
                    : Stack(
                        children: [
                          LayoutBuilder(
                            builder: (context, c) {
                              final wide =
                                  isDesktop && c.maxWidth >= _wideBreakpoint;
                              return Padding(
                                padding: _contentPadding,
                                child: wide
                                    ? _buildHorizontalLayout(
                                        c, item, player, colors)
                                    : _buildVerticalLayout(
                                        item, player, colors),
                              );
                            },
                          ),
                          QueueSheet(controller: _queueCtrl, player: player),
                        ],
                      ),
              ),
            );
          },
        );
      },
    );
  }

  /// Обложка для фона с кэшированием по id трека.
  ImageProvider? _artworkFor(MediaItem? item) {
    final url = item?.artUri?.toString();
    if (url == null || url.isEmpty) return null;

    if (item?.id == _cachedArtworkId) {
      return _cachedArtwork;
    }
    _cachedArtworkId = item?.id;
    _cachedArtwork = artworkImageProvider(url);
    return _cachedArtwork;
  }

    /// Обложка с анимацией масштаба, скругления и тенью.
  ///
  /// • На паузе: scale = 0.9, радиус углов = [_artworkRadiusPaused] (30).
  /// • При воспроизведении: scale = 1.0, радиус = [_artworkRadiusPlaying].
  /// • Тень рисуется внешним контейнером (без clipBehavior, чтобы не обрезалась),
  ///   а внутренний контейнер обрезает саму картинку по радиусу.
  Widget _buildArtwork({
    required MediaItem item,
    required double size,
    required PlayerServiceInterface player,
  }) {
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        final radius =
            playing ? _artworkRadiusPlaying : _artworkRadiusPaused;

        return AnimatedScale(
          scale: playing ? _artworkPlayingScale : _artworkPausedScale,
          duration: _artworkScaleDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: _artworkScaleDuration,
            curve: Curves.easeOutCubic,
            // Тень (рисуется снаружи, поэтому clipBehavior здесь НЕ задаём).
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(_artworkShadowOpacity),
                  blurRadius: _artworkShadowBlur,
                  spreadRadius: _artworkShadowSpread,
                  offset: const Offset(0, _artworkShadowOffsetY),
                ),
              ],
            ),
            child: AnimatedContainer(
              duration: _artworkScaleDuration,
              curve: Curves.easeOutCubic,
              // Обрезка самой обложки по радиусу (плавно анимируется).
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
              ),
              child: PlayerInteractiveArtwork(
                item: item,
                size: size,
                aspectRatio: artAspectRatio(item),
                player: player,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _artistText(String? artist, AppColors colors,
      {bool centered = false}) {
    return Text(
      artist ?? '',
      textAlign: centered ? TextAlign.center : null,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.textSecondary,
        fontSize: 16,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildVerticalLayout(
    MediaItem item,
    PlayerServiceInterface player,
    AppColors colors,
  ) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? _desktopMaxWidth : double.infinity,
        ),
        child: Column(
          children: [
            const Spacer(),
            LayoutBuilder(
              builder: (_, c) {
                final size = c.maxWidth.clamp(0, _mobileArtMaxSize).toDouble();
                return _buildArtwork(item: item, size: size, player: player);
              },
            ),
            const SizedBox(height: _vSpaceLarge),
            PlayerTitleScroller(text: item.title, colors: colors),
            _artistText(item.artist, colors, centered: true),
            const SizedBox(height: _vSpaceLarge),
            PlayerControls(player: player, colors: colors),
            const SizedBox(height: _vSpaceSmall),
            PlayerProgressBar(
              player: player,
              colors: colors,
              fallbackDuration: item.duration,
            ),
            const SizedBox(height: _vSpaceMedium),
            PlayerBottomActions(
              player: player,
              item: item,
              queueCtrl: _queueCtrl,
              colors: colors,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalLayout(
    BoxConstraints c,
    MediaItem item,
    PlayerServiceInterface player,
    AppColors colors,
  ) {
    final artworkSize = math
        .min(c.maxHeight * _artHeightFactor, _artPreferredMax)
        .clamp(_artMinSize, _artMaxSize)
        .toDouble();

    return Row(
      children: [
        // Анимированная обложка (увеличение при воспроизведении).
        _buildArtwork(item: item, size: artworkSize, player: player),
        const SizedBox(width: _hArtToControls),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlayerTitleScroller(text: item.title, colors: colors),
              const SizedBox(height: _hTitleToArtist),
              _artistText(item.artist, colors),
              const SizedBox(height: _hArtistToControls),
              Center(child: PlayerControls(player: player, colors: colors)),
              const SizedBox(height: _hControlsToProgress),
              PlayerProgressBar(
                player: player,
                colors: colors,
                fallbackDuration: item.duration,
              ),
              const SizedBox(height: _hProgressToActions),
              PlayerBottomActions(
                player: player,
                item: item,
                queueCtrl: _queueCtrl,
                colors: colors,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
