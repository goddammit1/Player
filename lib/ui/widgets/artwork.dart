import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

class Artwork extends ConsumerWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.memCacheSize,
    this.aspectRatio = 1.0,
  });

  final String? url;
  final double size;
  final double borderRadius;
  final double? memCacheSize;
  final double aspectRatio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
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
                aspectRatio: aspectRatio,
                fadeInDuration: const Duration(milliseconds: 100),
                placeholder: _Placeholder(colors: colors),
                errorWidget: _Placeholder(colors: colors),
              )
            : _Placeholder(colors: colors),
      ),
    );
  }
}

class _CroppedImage extends StatelessWidget {
  const _CroppedImage({
    required this.url,
    required this.size,
    required this.cacheSize,
    required this.aspectRatio,
    required this.fadeInDuration,
    required this.placeholder,
    required this.errorWidget,
  });

  final String url;
  final double size;
  final int cacheSize;
  final double aspectRatio;
  final Duration fadeInDuration;
  final Widget placeholder;
  final Widget errorWidget;

  @override
  Widget build(BuildContext context) {
    final imageWidth = size * aspectRatio;
    final imageHeight = size;
    final cacheWidth = (cacheSize * aspectRatio).round();
    final cacheHeight = cacheSize;

    return ClipRect(
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: SizedBox(
            width: imageWidth,
            height: imageHeight,
            child: CachedNetworkImage(
              imageUrl: url,
              width: imageWidth,
              height: imageHeight,
              fit: BoxFit.fill,
              memCacheWidth: cacheWidth,
              memCacheHeight: cacheHeight,
              fadeInDuration: fadeInDuration,
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => errorWidget,
            ),
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.elevatedVariant,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        color: colors.textTertiary,
        size: 28,
      ),
    );
  }
}

class ArtworkMosaic extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    if (urls.isEmpty) {
      return Artwork(url: null, size: size, borderRadius: borderRadius);
    }

    if (urls.length == 1) {
      return Artwork(
        url: urls.first,
        size: size,
        borderRadius: borderRadius,
        memCacheSize: size * 2,
        aspectRatio: _detectAspectRatio(urls.first),
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
              child: _Tile(url: cells[0], size: cell, colors: colors),
            ),
            Positioned(
              top: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[1], size: cell, colors: colors),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[2], size: cell, colors: colors),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(url: cells[3], size: cell, colors: colors),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.url, required this.size, required this.colors});
  final String? url;
  final double size;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cache = (size * dpr).round();

    if (url == null || url!.isEmpty) {
      return Container(color: colors.elevatedVariant);
    }

    final aspectRatio = _detectAspectRatio(url!);
    final imageWidth = size * aspectRatio;
    final imageHeight = size;
    final cacheWidth = (cache * aspectRatio).round();
    final cacheHeight = cache;

    return ClipRect(
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: SizedBox(
            width: imageWidth,
            height: imageHeight,
            child: CachedNetworkImage(
              imageUrl: url!,
              width: imageWidth,
              height: imageHeight,
              fit: BoxFit.fill,
              memCacheWidth: cacheWidth,
              memCacheHeight: cacheHeight,
              fadeInDuration: Duration.zero,
              placeholder: (_, _) => Container(color: colors.elevatedVariant),
              errorWidget: (_, _, _) => Container(color: colors.elevatedVariant),
            ),
          ),
        ),
      ),
    );
  }
}

double _detectAspectRatio(String? url) {
  if (url == null || url.isEmpty) return 1.0;
  final lower = url.toLowerCase();
  if (lower.contains('ytimg.com') ||
      lower.contains('youtube.com') ||
      lower.contains('googlevideo.com')) {
    return 16 / 9;
  }
  return 1.0;
}