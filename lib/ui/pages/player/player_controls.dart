// lib/ui/pages/player/player_controls.dart
//
// Кнопки управления воспроизведением: prev / play-pause / next
// с анимированным нажатием.

import 'package:audio_service/audio_service.dart'
    show PlaybackState, AudioProcessingState;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptic_helper.dart';
import '../../../core/providers/global_theme_provider.dart';
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
  // --- Размеры (вместо магических чисел) ---
  static const double _sideButtonBaseWidth = 56;
  static const double _sideButtonExpanded = 24;
  static const double _sideButtonCompressed = 20;
  static const double _playButtonBaseWidth = 170;
  static const double _playButtonExpanded = 40;
  static const double _playWidthSideReduction = 30;
  static const double _buttonHeight = 64;
  static const double _gapSmall = 5;
  static const double _gapMedium = 10;
  static const double _iconSizeSide = 28;
  static const double _iconSizePlay = 36;
  static const double _progressIndicatorSize = 24;

  // --- Длительности анимаций ---
  static const Duration _animDurationLong = Duration(milliseconds: 500);
  static const Duration _animDurationShort = Duration(milliseconds: 200);
  static const Duration _pressDuration = Duration(milliseconds: 100);
  static const Duration _releaseDuration = Duration(milliseconds: 450);

  late final AnimationController _playAnim = AnimationController(
    vsync: this,
    duration: _animDurationLong,
    value: 0,
  );
  late final AnimationController _prevAnim = AnimationController(
    vsync: this,
    duration: _animDurationShort,
    value: 0,
  );
  late final AnimationController _nextAnim = AnimationController(
    vsync: this,
    duration: _animDurationShort,
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

  // --- Унифицированные обработчики нажатий ---

  void _onPointerDown(
    bool isPressed,
    VoidCallback setPressed,
    AnimationController anim,
  ) {
    if (!isPressed) {
      setPressed();
      anim.animateTo(1, duration: _pressDuration, curve: Curves.easeInOutQuart);
    }
  }

  void _onRelease(
    bool isPressed,
    VoidCallback setUnpressed,
    AnimationController anim,
  ) {
    if (isPressed) {
      setUnpressed();
      anim.animateTo(0, duration: _releaseDuration, curve: Curves.easeOutBack);
    }
  }

  void _onPlayPointerDown(PointerDownEvent event) =>
      _onPointerDown(_isPlayPressed, () => _isPlayPressed = true, _playAnim);
  void _onPlayPointerUp(PointerUpEvent event) =>
      _onRelease(_isPlayPressed, () => _isPlayPressed = false, _playAnim);
  void _onPlayPointerCancel(PointerCancelEvent event) =>
      _onRelease(_isPlayPressed, () => _isPlayPressed = false, _playAnim);

  void _onPrevPointerDown(PointerDownEvent event) =>
      _onPointerDown(_isPrevPressed, () => _isPrevPressed = true, _prevAnim);
  void _onPrevPointerUp(PointerUpEvent event) =>
      _onRelease(_isPrevPressed, () => _isPrevPressed = false, _prevAnim);
  void _onPrevPointerCancel(PointerCancelEvent event) =>
      _onRelease(_isPrevPressed, () => _isPrevPressed = false, _prevAnim);

  void _onNextPointerDown(PointerDownEvent event) =>
      _onPointerDown(_isNextPressed, () => _isNextPressed = true, _nextAnim);
  void _onNextPointerUp(PointerUpEvent event) =>
      _onRelease(_isNextPressed, () => _isNextPressed = false, _nextAnim);
  void _onNextPointerCancel(PointerCancelEvent event) =>
      _onRelease(_isNextPressed, () => _isNextPressed = false, _nextAnim);

  /// Универсальный построитель боковых кнопок (prev / next).
  Widget _buildSideButton({
    required double width,
    required IconData icon,
    required VoidCallback onTap,
    required PointerDownEventListener onPointerDown,
    required PointerUpEventListener onPointerUp,
    required PointerCancelEventListener onPointerCancel,
  }) {
    return Listener(
      onPointerDown: onPointerDown,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerCancel,
      child: GestureDetector(
        onTap: onTap,
        child: Material(
          color: widget.colors.elevated,
          borderRadius: BorderRadius.circular(32), // всегда 32
          child: SizedBox(
            width: width,
            height: _buttonHeight,
            child: Icon(
              icon,
              color: widget.colors.textPrimary,
              size: _iconSizeSide,
            ),
          ),
        ),
      ),
    );
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

            final prevWidth = _sideButtonBaseWidth -
                _sideButtonCompressed * playExpanded +
                _sideButtonExpanded * prevExpanded;
            final nextWidth = _sideButtonBaseWidth -
                _sideButtonCompressed * playExpanded +
                _sideButtonExpanded * nextExpanded;
            final playWidth = _playButtonBaseWidth +
                _playButtonExpanded * playExpanded -
                _playWidthSideReduction * (prevExpanded + nextExpanded);

            return Row(
              // <<< ИСПРАВЛЕНИЕ БАГА:
              // mainAxisSize.min сжимает Row до содержимого, и родитель
              // центрует его. Без этого Row растягивался на всю ширину
              // и прижимал кнопки влево (mainAxisAlignment по умолчанию
              // = start), из-за чего на экранах шире 360 px блок был
              // смещён влево.
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: _gapSmall),
                _buildSideButton(
                  width: prevWidth,
                  icon: Icons.skip_previous_rounded,
                  onTap: () {
                    widget.player.skipToPrevious();
                    HapticHelper.light(ref: ref);
                  },
                  onPointerDown: _onPrevPointerDown,
                  onPointerUp: _onPrevPointerUp,
                  onPointerCancel: _onPrevPointerCancel,
                ),
                const SizedBox(width: _gapMedium),
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
                      borderRadius: BorderRadius.circular(playing ? 20 : 32),
                      child: SizedBox(
                        width: playWidth,
                        height: _buttonHeight,
                        child: Center(
                          child: loading
                              ? SizedBox(
                                  width: _progressIndicatorSize,
                                  height: _progressIndicatorSize,
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
                                  size: _iconSizePlay,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: _gapMedium),
                _buildSideButton(
                  width: nextWidth,
                  icon: Icons.skip_next_rounded,
                  onTap: () {
                    HapticHelper.light(ref: ref);
                    widget.player.skipToNext();
                  },
                  onPointerDown: _onNextPointerDown,
                  onPointerUp: _onNextPointerUp,
                  onPointerCancel: _onNextPointerCancel,
                ),
                const SizedBox(width: _gapSmall),
              ],
            );
          },
        );
      },
    );
  }
}