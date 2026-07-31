// lib/core/artwork_helper.dart

import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';

class ArtworkHelper {
  static final ImagePicker _picker = ImagePicker();
  static final Map<String, String> _customArtCache = {};
  static bool _initialized = false;

  /// Инициализация кэша кастомных обложек при старте приложения (вызывать в main.dart)
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('custom_art_'));
      for (final key in keys) {
        final trackId = key.replaceFirst('custom_art_', '');
        final path = prefs.getString(key);
        if (path != null && File(path).existsSync()) {
          _customArtCache[trackId] = path;
        }
      }
    } catch (_) {}
    _initialized = true;
  }

  /// Синхронно возвращает путь к кастомной обложке из быстрой памяти
  static String? getCustomArtworkSync(String trackId) {
    final path = _customArtCache[trackId];
    if (path != null && File(path).existsSync()) {
      return path;
    }
    return null;
  }

  /// Выбор изображения из галереи, сброс кэша картинок Flutter и персист на диск
  static Future<String?> pickAndSaveArtwork(String trackId) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 90,
      );

      if (file == null) return null;

      final appDir = await getApplicationDocumentsDirectory();
      final artDir = Directory('${appDir.path}/custom_artworks');
      if (!await artDir.exists()) {
        await artDir.create(recursive: true);
      }

      final savedFile = File('${artDir.path}/$trackId.jpg');

      // Сбрасываем кэш картинок Flutter, чтобы сменившееся изображение обновилось в UI
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await File(file.path).copy(savedFile.path);

      _customArtCache[trackId] = savedFile.path;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('custom_art_$trackId', savedFile.path);

      return savedFile.path;
    } catch (_) {
      return null;
    }
  }
}

bool isWideArt(dynamic item) {
  String sourceId;
  String? artworkUrl;

  if (item is Track) {
    sourceId = item.sourceId;
    artworkUrl = item.artworkUrl;
  } else if (item is MediaItem) {
    sourceId = item.extras?['sourceId'] as String? ?? '';
    artworkUrl = item.artUri?.toString();
  } else {
    throw ArgumentError(
      'isWideArt принимает только Track или MediaItem, получен: ${item.runtimeType}',
    );
  }

  if (sourceId == 'youtube') return true;
  return isWideArtUrl(artworkUrl);
}

bool isWideArtUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final lower = url.toLowerCase();
  return lower.contains('ytimg.com') ||
      lower.contains('youtube.com') ||
      lower.contains('googlevideo.com');
}

double artAspectRatio(dynamic item) => isWideArt(item) ? 16 / 9 : 1.0;

double urlAspectRatio(String? url) => isWideArtUrl(url) ? 16 / 9 : 1.0;