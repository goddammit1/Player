import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../core/providers/appearance_provider.dart';
import '../../../core/providers/global_theme_provider.dart';
import 'mesh_background.dart';

/// Фон страницы плеера: градиент из палитры, mesh из цветов обложки или
/// размытая обложка.
///
/// Градиент рисуется всегда и служит подложкой: он виден, пока обложка
/// грузится, если она не загрузилась или её нет.
class PlayerBackground extends StatelessWidget {
  const PlayerBackground({
    super.key,
    required this.style,
    required this.colors,
    required this.artwork,
    this.animate = true,
    required this.child,
  });

  final PlayerBackgroundStyle style;
  final AppColors colors;

  /// Обложка текущего трека; `null` — обложки нет.
  final ImageProvider? artwork;

  /// `false` — фон не анимируется (плеер свёрнут и не виден). На [child]
  /// не влияет.
  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final artwork = this.artwork;
    final gradient = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.gradientTop, colors.gradientTop, colors.gradientBottom],
        stops: const [0.0, 0.35, 1.0],
      ),
    );


    // Структура дерева не зависит от стиля и обложки: иначе при их смене
    // пересоздавался бы весь контент плеера вместе с состоянием.
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(decoration: gradient),
        TickerMode(
          enabled: animate,
          // Свёрнутый плеер меняет обложку сразу: иначе замороженные переходы
          // копили бы слои, и при разворачивании гасли бы все разом.
          child: AnimatedSwitcher(
            duration: animate ? _crossFade : Duration.zero,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: [...previous, ?current],
            ),
            child: switch (style) {
              PlayerBackgroundStyle.blur when artwork != null =>
                _BlurredArtwork(key: ValueKey(artwork), artwork: artwork),
              PlayerBackgroundStyle.mesh => MeshBackground(
                  key: const ValueKey(PlayerBackgroundStyle.mesh),
                  colors: colors.meshColors,
                ),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
        child,
      ],
    );
  }

  /// Как у перехода палитры (AnimatedPaletteNotifier).
  static const _crossFade = Duration(milliseconds: 1000);
}

/// Обложка, уменьшенная до [_decodeWidth] и растянутая на весь экран.
/// Мелкий декод сам размывает картинку, лёгкий блюр убирает ступеньки.
/// Пока обложка не загрузилась или если она битая, не рисуется ничего,
/// и виден градиент-подложка.
class _BlurredArtwork extends StatelessWidget {
  const _BlurredArtwork({super.key, required this.artwork});

  final ImageProvider artwork;

  static const _decodeWidth = 48;
  static const _sigma = 16.0;
  static const _fadeIn = Duration(milliseconds: 300);

  /// Затемнение поверх обложки: белый текст на белой обложке ≈ 5.7:1.
  /// Подбирается на устройстве (фаза 6 плана).
  static const _scrim = Color(0x99000000);

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Image(
        image: ResizeImage(artwork, width: _decodeWidth),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
        frameBuilder: (_, image, frame, synchronous) {
          final loaded = synchronous || frame != null;
          return AnimatedOpacity(
            opacity: loaded ? 1 : 0,
            duration: _fadeIn,
            child: loaded
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        imageFilter:
                            ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
                        child: image,
                      ),
                      const ColoredBox(color: _scrim),
                    ],
                  )
                : image,
          );
        },
      ),
    );
  }
}
