import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';

/// Источник картинки для обложки из `artUri`: FileImage для локальных файлов,
/// CachedNetworkImageProvider для сети; `null`, если локального файла нет.
ImageProvider? artworkImageProvider(String url) {
  final isLocalFile = url.startsWith('/') || url.startsWith('file://');
  if (!isLocalFile) return CachedNetworkImageProvider(url);

  final filePath = url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
  final file = File(filePath);
  return file.existsSync() ? FileImage(file) : null;
}
