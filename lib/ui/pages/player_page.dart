// lib/ui/pages/player_page.dart

import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/queue_sheet.dart';

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
      body: SafeArea(child: PlayerContent()),
    );
  }
}

class PlayerContent extends ConsumerStatefulWidget {
  const PlayerContent({super.key, this.onClose});
  final VoidCallback? onClose;

  @override
  ConsumerState<PlayerContent> createState() => _PlayerContentState();
}

class _PlayerContentState extends ConsumerState<PlayerContent>
    with TickerProviderStateMixin {
  late final QueueSheetController _queueCtrl = QueueSheetController(
    vsync: this,
  );

  @override
  void dispose() {
    _queueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    final colors = ref.watch(animatedPaletteProvider);

    final bgDecoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.gradientTop, colors.gradientTop, colors.gradientBottom],
        stops: const [0.0, 0.35, 1.0],
      ),
    );

    return Container(
      decoration: bgDecoration,
      child: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snap) {
          final item = snap.data;

          if (item == null) {
            return Center(
              child: Text(
                'No track',
                style: TextStyle(color: colors.textSecondary),
              ),
            );
          }

          return Stack(
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  final wide = isDesktop && c.maxWidth >= _wideBreakpoint;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                    child: wide
                        ? _buildHorizontalLayout(c, item, player, colors)
                        : _buildVerticalLayout(item, player, colors),
                  );
                },
              ),
              QueueSheet(controller: _queueCtrl, player: player),
            ],
          );
        },
      ),
    );
  }

  /// Ширина окна (на десктопе), при которой включается горизонтальная
  /// раскладка плеера. Мобильные платформы всегда используют вертикальную.
  static const double _wideBreakpoint = 1000;

  /// Вертикальная раскладка (как на мобильных) — используется по умолчанию
  /// и на десктопе в узких окнах. На десктопе контент центрируется
  /// по горизонтали и ограничивается по ширине (Android/iOS не затронуты).
  Widget _buildVerticalLayout(
    MediaItem item,
    PlayerServiceInterface player,
    AppColors colors,
  ) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? 600 : double.infinity,
        ),
        child: Column(
          children: [
            const Expanded(child: SizedBox.shrink()),
            LayoutBuilder(
              builder: (_, c) {
                final size = c.maxWidth.clamp(0, 420.0).toDouble();
                return PlayerInteractiveArtwork(
                  item: item,
                  size: size,
                  aspectRatio: artAspectRatio(item),
                  player: player,
                );
              },
            ),
            const SizedBox(height: 30),
            PlayerTitleScroller(text: item.title, colors: colors),
            const SizedBox(height: 0),
            Text(
              item.artist ?? '',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 30),
            PlayerControls(player: player, colors: colors),
            const SizedBox(height: 15),
            PlayerProgressBar(
              player: player,
              colors: colors,
              fallbackDuration: item.duration,
            ),
            const SizedBox(height: 20),
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

  /// Горизонтальная раскладка для широких десктопных окон:
  /// обложка слева, управление/прогресс справа.
  Widget _buildHorizontalLayout(
    BoxConstraints c,
    MediaItem item,
    PlayerServiceInterface player,
    AppColors colors,
  ) {
    final artworkSize = math.min(c.maxHeight * 0.85, 480.0).clamp(280.0, 520.0);

    return Row(
      children: [
        PlayerInteractiveArtwork(
          item: item,
          size: artworkSize,
          aspectRatio: artAspectRatio(item),
          player: player,
        ),
        const SizedBox(width: 56),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlayerTitleScroller(text: item.title, colors: colors),
              const SizedBox(height: 4),
              Text(
                item.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: PlayerControls(player: player, colors: colors),
              ),
              const SizedBox(height: 20),
              PlayerProgressBar(
                player: player,
                colors: colors,
                fallbackDuration: item.duration,
              ),
              const SizedBox(height: 24),
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
