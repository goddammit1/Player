// lib/ui/widgets/artwork.dart

import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/providers.dart';

class Artwork extends ConsumerWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.trackId,
    this.borderRadius = 8,
    this.memCacheSize,
    this.aspectRatio = 1.0,
  });

  final String? url;
  final String? trackId;
  final double size;
  final double borderRadius;
  final double? memCacheSize;
  final double aspectRatio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (memCacheSize ?? size * dpr).round();

    // 1. Проверяем наличие кастомной обложки на диске по trackId
    final customPath =
        trackId != null ? ArtworkHelper.getCustomArtworkSync(trackId!) : null;
    final effectiveUrl = customPath ?? url;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: effectiveUrl != null && effectiveUrl.isNotEmpty
            ? _CroppedImage(
                url: effectiveUrl,
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

    final isLocalFile = url.startsWith('/') || url.startsWith('file://');
    final filePath = url.startsWith('file://')
        ? Uri.parse(url).toFilePath()
        : url;

    // Генерируем ключ на основе даты модификации файла для сброса кеша визуала
    Key? imageKey;
    if (isLocalFile) {
      try {
        final f = File(filePath);
        if (f.existsSync()) {
          imageKey = ValueKey('${filePath}_${f.lastModifiedSync().millisecondsSinceEpoch}');
        }
      } catch (_) {}
    }

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
            child: isLocalFile
                ? Image.file(
                    File(filePath),
                    key: imageKey,
                    width: imageWidth,
                    height: imageHeight,
                    fit: BoxFit.fill,
                    errorBuilder: (_, _, _) => errorWidget,
                  )
                : CachedNetworkImage(
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
    this.coverCustomUrl,
    this.trackIds = const [],
  });

  final List<String> urls;
  final double size;
  final double borderRadius;
  final String? coverCustomUrl;

  /// Исходные trackId (по одному на каждый [url]) — для подстановки
  /// кастомных обложек треков в ячейках мозаики.
  final List<String> trackIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final effectiveUrls = coverCustomUrl != null && coverCustomUrl!.isNotEmpty
        ? [coverCustomUrl!]
        : urls;

    if (effectiveUrls.isEmpty) {
      return Artwork(url: null, size: size, borderRadius: borderRadius);
    }

    if (effectiveUrls.length == 1) {
      return Artwork(
        url: effectiveUrls.first,
        trackId: trackIds.isNotEmpty ? trackIds.first : null,
        size: size,
        borderRadius: borderRadius,
        memCacheSize: size * 2,
        aspectRatio: urlAspectRatio(effectiveUrls.first),
      );
    }

    final cells =
        List<String?>.generate(4, (i) => i < urls.length ? urls[i] : null);
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
              child: _Tile(
                url: cells[0],
                trackId: trackIds.isNotEmpty ? trackIds[0] : null,
                size: cell,
                colors: colors,
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(
                url: cells[1],
                trackId: trackIds.length > 1 ? trackIds[1] : null,
                size: cell,
                colors: colors,
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              width: cell,
              height: cell,
              child: _Tile(
                url: cells[2],
                trackId: trackIds.length > 2 ? trackIds[2] : null,
                size: cell,
                colors: colors,
              ),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              width: cell,
              height: cell,
              child: _Tile(
                url: cells[3],
                trackId: trackIds.length > 3 ? trackIds[3] : null,
                size: cell,
                colors: colors,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.url,
    required this.size,
    required this.colors,
    this.trackId,
  });
  final String? url;
  final double size;
  final dynamic colors;
  final String? trackId;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cache = (size * dpr).round();

    // Подставляем кастомную обложку трека, если она есть на диске.
    final customPath =
        trackId != null ? ArtworkHelper.getCustomArtworkSync(trackId!) : null;
    final effectiveUrl = customPath ?? url;

    if (effectiveUrl == null || effectiveUrl.isEmpty) {
      return Container(color: colors.elevatedVariant);
    }

    final isLocalFile =
        effectiveUrl.startsWith('/') || effectiveUrl.startsWith('file://');
    final filePath = effectiveUrl.startsWith('file://')
        ? Uri.parse(effectiveUrl).toFilePath()
        : effectiveUrl;

    final aspectRatio = urlAspectRatio(effectiveUrl);
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
            child: isLocalFile
                ? Image.file(
                    File(filePath),
                    width: imageWidth,
                    height: imageHeight,
                    fit: BoxFit.fill,
                    errorBuilder: (_, _, _) =>
                        Container(color: colors.elevatedVariant),
                  )
                : CachedNetworkImage(
                    imageUrl: effectiveUrl,
                    width: imageWidth,
                    height: imageHeight,
                    fit: BoxFit.fill,
                    memCacheWidth: cacheWidth,
                    memCacheHeight: cacheHeight,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, _) =>
                        Container(color: colors.elevatedVariant),
                    errorWidget: (_, _, _) =>
                        Container(color: colors.elevatedVariant),
                  ),
          ),
        ),
      ),
    );
  }
}