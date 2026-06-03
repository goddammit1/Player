import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../main.dart' show AppColors;

/// Универсальный артворк-плейсхолдер. Отрисовывает либо обложку с
/// `imageUrl`, либо мягкий серый плейсхолдер с нотой. Используется во
/// всех списках и карточках — это позволяет согласованно управлять
/// `memCacheWidth/Height` (декодирование уменьшенного bitmap'а) и
/// fallback-поведением.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.memCacheSize,
  });

  final String? url;
  final double size;
  final double borderRadius;

  /// Размер декодированного bitmap'а в логических пикселях. По
  /// умолчанию = `size * 2` (≈ retina-плотность). Указывать вручную
  /// стоит для очень крупных артов на player_page, где имеет смысл
  /// `min(displaySize * dpr, 720)`.
  final double? memCacheSize;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (memCacheSize ?? size * dpr).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: url != null && url!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                memCacheWidth: cacheSize,
                memCacheHeight: cacheSize,
                fadeInDuration: const Duration(milliseconds: 100),
                placeholder: (_, _) => const _Placeholder(),
                errorWidget: (_, _, _) => const _Placeholder(),
              )
            : const _Placeholder(),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceVariant,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        color: AppColors.textTertiary,
        size: 28,
      ),
    );
  }
}

/// Мозаика 2×2 из обложек первых четырёх треков плейлиста. Если
/// треков меньше — недостающие ячейки заполняются плейсхолдером.
/// Если треков нет вовсе — рисует один большой плейсхолдер.
class ArtworkMosaic extends StatelessWidget {
  const ArtworkMosaic({
    super.key,
    required this.urls,
    required this.size,
    this.borderRadius = 16,
  });

  final List<String> urls;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) {
      return Artwork(url: null, size: size, borderRadius: borderRadius);
    }

    if (urls.length == 1) {
      return Artwork(
        url: urls.first,
        size: size,
        borderRadius: borderRadius,
        memCacheSize: size * 2,
      );
    }

    final cells = List<String?>.generate(4, (i) => i < urls.length ? urls[i] : null);
    final cell = size / 2;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        // Используем Stack вместо Column+Row — полный контроль позиционирования
        child: Stack(
          children: [
            // Верхний ряд
            Positioned(
              top: 0,
              left: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[0], size: cell),
            ),
            Positioned(
              top: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[1], size: cell),
            ),
            // Нижний ряд
            Positioned(
              bottom: 0,
              left: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[2], size: cell),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[3], size: cell),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.url, required this.size});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cache = (size * dpr).round();
    
    if (url == null || url!.isEmpty) {
      return Container(color: AppColors.surfaceVariant);
    }
    
    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      width: size,
      height: size,
      memCacheWidth: cache,
      memCacheHeight: cache,
      fadeInDuration: Duration.zero,  // убираем fade для мозаики
      placeholder: (_, _) => Container(color: AppColors.surfaceVariant),
      errorWidget: (_, _, _) => Container(color: AppColors.surfaceVariant),
    );
  }
}
