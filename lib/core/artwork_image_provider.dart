import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';

/// Источник картинки для обложки из `artUri`: FileImage для локальных файлов,
/// CachedNetworkImageProvider для сети; `null`, если локального файла нет.
ImageProvider? artworkImageProvider(String url) {
  if (!isLocalArtworkUrl(url)) return CachedNetworkImageProvider(url);

  final file = File(localArtworkPath(url));
  return file.existsSync() ? FileImage(file) : null;
}

final _windowsPathRe = RegExp(r'^[A-Za-z]:[\\/]');

/// Обложка — локальный файл: путь POSIX (`/…`), `file://`-URI или путь
/// Windows (`C:\…`, `\\server\…`). Кастомные обложки на Windows хранятся
/// именно так — без этой проверки они грузились бы как сетевой URL.
bool isLocalArtworkUrl(String url) =>
    url.startsWith('/') ||
    url.startsWith('file://') ||
    url.startsWith(r'\\') ||
    _windowsPathRe.hasMatch(url);

/// Путь к файлу для [isLocalArtworkUrl]-обложки (`file://` → путь ОС).
String localArtworkPath(String url) =>
    url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
