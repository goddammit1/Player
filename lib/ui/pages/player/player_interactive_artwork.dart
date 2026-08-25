// lib/ui/pages/player/player_interactive_artwork.dart
//
// Интерактивная обложка трека с оверлеем «Change album / Restore original».
// Вынесена из player_page.dart (декомпозиция монолита, план §1.3).

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/artwork_helper.dart';
import '../../../core/platform/haptic_helper.dart';
import '../../../core/player_service_interface.dart';
import '../../widgets/artwork.dart';

class PlayerInteractiveArtwork extends ConsumerStatefulWidget {
  const PlayerInteractiveArtwork({
    super.key,
    required this.item,
    required this.size,
    required this.aspectRatio,
    required this.player,
  });

  final MediaItem item;
  final double size;
  final double aspectRatio;
  final PlayerServiceInterface player;

  @override
  ConsumerState<PlayerInteractiveArtwork> createState() =>
      _PlayerInteractiveArtworkState();
}

class _PlayerInteractiveArtworkState
    extends ConsumerState<PlayerInteractiveArtwork> {
  bool _showOverlay = false;

  void _toggleOverlay() {
    HapticHelper.light(ref: ref);
    setState(() {
      _showOverlay = !_showOverlay;
    });
  }

  void _hideOverlay() {
    if (_showOverlay) {
      setState(() {
        _showOverlay = false;
      });
    }
  }

  Future<void> _onChangeAlbum() async {
    HapticHelper.medium(ref: ref);
    _hideOverlay();

    final trackId = widget.item.extras?['trackId'] as String? ?? widget.item.id;

    final newPath = await ArtworkHelper.pickAndSaveArtwork(trackId);

    if (newPath != null && mounted) {
      // Это обновит MediaItem на Uri.file(newPath), что автоматически запустит
      // перерасчет динамических цветов в animatedPaletteProvider!
      await widget.player.updateCustomArtwork(trackId, newPath);
    }
  }

  Future<void> _onResetAlbum() async {
    HapticHelper.medium(ref: ref);
    _hideOverlay();

    final trackId = widget.item.extras?['trackId'] as String? ?? widget.item.id;

    await widget.player.resetCustomArtwork(trackId);
  }

  @override
  Widget build(BuildContext context) {
    final trackId = widget.item.extras?['trackId'] as String? ?? widget.item.id;
    final hasCustomArt = ArtworkHelper.getCustomArtworkSync(trackId) != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleOverlay,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            children: [
              // 1. Сама обложка
              Artwork(
                url: widget.item.artUri?.toString(),
                trackId: trackId,
                size: widget.size,
                borderRadius: 10,
                memCacheSize: 600,
                aspectRatio: widget.aspectRatio,
              ),

              // 2. Затемняющий анимированный оверлей
              AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: IgnorePointer(
                  ignoring: !_showOverlay,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    width: widget.size,
                    height: widget.size,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Кнопка "Change album" — всегда присутствует
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _onChangeAlbum,
                            child: const Padding(
                              padding: EdgeInsets.all(14.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.image_outlined,
                                    color: Colors.white,
                                    size: 38,
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    'Change album',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Кнопка "Restore original" — только если есть кастомная обложка
                          if (hasCustomArt)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _onResetAlbum,
                              child: Padding(
                                padding: const EdgeInsets.all(14.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.restore_outlined,
                                      color: Colors.white.withValues(
                                        alpha: 0.8,
                                      ),
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Restore original',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.8,
                                        ),
                                        fontSize: 15,
                                        fontWeight: FontWeight.w400,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
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