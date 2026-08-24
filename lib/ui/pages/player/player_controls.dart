// lib/ui/pages/player/player_controls.dart
//
// Кнопки управления воспроизведением: prev / play-pause / next
// с анимированным нажатием. Вынесены из player_page.dart (план §1.3).

import 'package:audio_service/audio_service.dart' show PlaybackState, AudioProcessingState;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/haptic_helper.dart';
import '../../../core/global_theme_provider.dart';
import '../../../core/player_service_interface.dart';

class PlayerControls extends ConsumerStatefulWidget {
  const PlayerControls({super.key, required this.player, required this.colors});
  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  ConsumerState<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends ConsumerState<PlayerControls>
    with TickerProviderStateMixin {
  late final AnimationController _playAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    value: 0,
  );

  late final AnimationController _prevAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );

  late final AnimationController _nextAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );

  bool _isPlayPressed = false;
  bool _isPrevPressed = false;
  bool _isNextPressed = false;

  @override
  void dispose() {
    _playAnim.dispose();
    _prevAnim.dispose();
    _nextAnim.dispose();
    super.dispose();
  }

  void _onPlayPointerDown(PointerDownEvent event) {
    if (!_isPlayPressed) {
      _isPlayPressed = true;
      _playAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOutQuart,
      );
    }
  }

  void _onPlayPointerUp(PointerUpEvent event) => _onPlayRelease();
  void _onPlayPointerCancel(PointerCancelEvent event) => _onPlayRelease();

  void _onPlayRelease() {
    if (_isPlayPressed) {
      _isPlayPressed = false;
      _playAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutBack,
      );
    }
  }

  void _onPrevPointerDown(PointerDownEvent event) {
    if (!_isPrevPressed) {
      _isPrevPressed = true;
      _prevAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOutQuart,
      );
    }
  }

  void _onPrevPointerUp(PointerUpEvent event) => _onPrevRelease();
  void _onPrevPointerCancel(PointerCancelEvent event) => _onPrevRelease();

  void _onPrevRelease() {
    if (_isPrevPressed) {
      _isPrevPressed = false;
      _prevAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutBack,
      );
    }
  }

  void _onNextPointerDown(PointerDownEvent event) {
    if (!_isNextPressed) {
      _isNextPressed = true;
      _nextAnim.animateTo(
        1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOutQuart,
      );
    }
  }

  void _onNextPointerUp(PointerUpEvent event) => _onNextRelease();
  void _onNextPointerCancel(PointerCancelEvent event) => _onNextRelease();

  void _onNextRelease() {
    if (_isNextPressed) {
      _isNextPressed = false;
      _nextAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutBack,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.player.playbackState,
      builder: (context, snap) {
        final st = snap.data;
        final loading =
            st != null &&
            (st.processingState == AudioProcessingState.loading ||
                st.processingState == AudioProcessingState.buffering);
        final playing = st?.playing ?? false;

        return AnimatedBuilder(
          animation: Listenable.merge([_playAnim, _prevAnim, _nextAnim]),
          builder: (context, _) {
            final playExpanded = _playAnim.value;
            final prevExpanded = _prevAnim.value;
            final nextExpanded = _nextAnim.value;

            final prevWidth = 56 - 20 * playExpanded + 24 * prevExpanded;
            final nextWidth = 56 - 20 * playExpanded + 24 * nextExpanded;
            final playWidth =
                170 + 40 * playExpanded - 30 * (prevExpanded + nextExpanded);

            final isPlayPressed = _playAnim.value > 0 || _isPlayPressed;
            final isPrevPressed = _prevAnim.value > 0 || _isPrevPressed;
            final isNextPressed = _nextAnim.value > 0 || _isNextPressed;

            return Row(
              children: [
                const SizedBox(width: 5),
                Listener(
                  onPointerDown: _onPrevPointerDown,
                  onPointerUp: _onPrevPointerUp,
                  onPointerCancel: _onPrevPointerCancel,
                  child: GestureDetector(
                    onTap: () {
                      widget.player.skipToPrevious();
                      HapticHelper.light(ref: ref);
                    },
                    child: Material(
                      color: widget.colors.elevated,
                      borderRadius: BorderRadius.circular(
                        isPrevPressed ? 32 : 32,
                      ),
                      child: SizedBox(
                        width: prevWidth,
                        height: 64,
                        child: Icon(
                          Icons.skip_previous_rounded,
                          color: widget.colors.textPrimary,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Listener(
                  onPointerDown: _onPlayPointerDown,
                  onPointerUp: _onPlayPointerUp,
                  onPointerCancel: _onPlayPointerCancel,
                  child: GestureDetector(
                    onTap: () {
                      playing ? widget.player.pause() : widget.player.play();
                      HapticHelper.medium(ref: ref);
                    },
                    child: Material(
                      color: widget.colors.elevatedHi,
                      borderRadius: BorderRadius.circular(
                        playing
                            ? (isPlayPressed ? 20 : 20)
                            : (isPlayPressed ? 32 : 32),
                      ),
                      child: SizedBox(
                        width: playWidth,
                        height: 64,
                        child: Center(
                          child: loading
                              ? SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: widget.colors.textPrimary,
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: widget.colors.textPrimary,
                                  size: 36,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Listener(
                  onPointerDown: _onNextPointerDown,
                  onPointerUp: _onNextPointerUp,
                  onPointerCancel: _onNextPointerCancel,
                  child: GestureDetector(
                    onTap: () {
                      HapticHelper.light(ref: ref);
                      widget.player.skipToNext();
                    },
                    child: Material(
                      color: widget.colors.elevated,
                      borderRadius: BorderRadius.circular(
                        isNextPressed ? 32 : 32,
                      ),
                      child: SizedBox(
                        width: nextWidth,
                        height: 64,
                        child: Icon(
                          Icons.skip_next_rounded,
                          color: widget.colors.textPrimary,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
              ],
            );
          },
        );
      },
    );
  }
}