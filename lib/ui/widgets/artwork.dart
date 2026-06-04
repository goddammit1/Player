import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../main.dart' show AppColors;

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
            ? _CroppedImage(
                url: url!,
                size: size,
                cacheSize: cacheSize,
                fadeInDuration: const Duration(milliseconds: 100),
                placeholder: const _Placeholder(),
                errorWidget: const _Placeholder(),
              )
            : const _Placeholder(),
      ),
    );
  }
}

class _CroppedImage extends StatelessWidget {
  const _CroppedImage({
    required this.url,
    required this.size,
    required this.cacheSize,
    required this.fadeInDuration,
    required this.placeholder,
    required this.errorWidget,
  });

  final String url;
  final double size;
  final int cacheSize;
  final Duration fadeInDuration;
  final Widget placeholder;
  final Widget errorWidget;

  @override
  Widget build(BuildContext context) {
    final imageWidth = size * 16 / 9;
    final imageHeight = size;
    final cacheWidth = (cacheSize * 16 / 9).round();
    final cacheHeight = cacheSize;

    return ClipRect(
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: CachedNetworkImage(
            imageUrl: url,
            width: imageWidth,
            height: imageHeight,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            memCacheHeight: cacheHeight,
            fadeInDuration: fadeInDuration,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => errorWidget,
          ),
        ),
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
        child: Stack(
          children: [
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
    
    final imageWidth = size * 16 / 9;
    final imageHeight = size;
    final cacheWidth = (cache * 16 / 9).round();
    final cacheHeight = cache;

    return ClipRect(
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: CachedNetworkImage(
            imageUrl: url!,
            width: imageWidth,
            height: imageHeight,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            memCacheHeight: cacheHeight,
            fadeInDuration: Duration.zero,
            placeholder: (_, _) => Container(color: AppColors.surfaceVariant),
            errorWidget: (_, _, _) => Container(color: AppColors.surfaceVariant),
          ),
        ),
      ),
    );
  }
}
