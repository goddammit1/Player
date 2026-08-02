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

  /// Выбор изображения для плейлиста (без привязки к trackId)
  static Future<String?> pickCustomArtwork() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 90,
      );
      if (file == null) return null;

      final appDir = await getApplicationDocumentsDirectory();
      final artDir = Directory('${appDir.path}/custom_artworks/playlists');
      if (!await artDir.exists()) await artDir.create(recursive: true);

      final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = File('${artDir.path}/$fileName');
      await File(file.path).copy(savedFile.path);

      // Обновляем mtime и сбрасываем кэш Flutter
      try { await savedFile.setLastModified(DateTime.now()); } catch (_) {}
      await FileImage(savedFile).evict();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      return savedFile.path;
    } catch (_) {
      return null;
    }
  }
  static final Map<String, String> _customArtCache = {};
  static bool _initialized = false;

  /// Инициализация кэша кастомных обложек при старте приложения (вызывать в main.dart)
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      await Directory('${appDir.path}/custom_artworks').create(recursive: true);
      await Directory('${appDir.path}/custom_artworks/playlists').create(recursive: true);

      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('custom_art_'));
      for (final key in keys) {
        final trackId = key.replaceFirst('custom_art_', '');
        final path = prefs.getString(key);
        if (path != null && File(path).existsSync()) {
          _customArtCache[trackId] = path;
        }
      }
    } catch (e) {
      debugPrint('[ArtworkHelper.init] Failed to initialize: $e');
    }
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

      // 1. Копируем файл
      await File(file.path).copy(savedFile.path);

      // 2. Обновляем время модификации файла, чтобы Flutter точно увидел изменения
      try {
        await savedFile.setLastModified(DateTime.now());
      } catch (_) {}

      // 3. Выселяем точечно старый FileImage из кэша Flutter
      await FileImage(savedFile).evict();

      // 4. Очищаем общий кэш изображений
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      _customArtCache[trackId] = savedFile.path;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('custom_art_$trackId', savedFile.path);

      return savedFile.path;
    } catch (_) {
      return null;
    }
  }

  /// Удаляет кастомную обложку трека (файл + кэш + SharedPreferences)
  static Future<void> removeCustomArtwork(String trackId) async {
    try {
      // Удаляем файл с диска
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/custom_artworks/$trackId.jpg');
      if (await file.exists()) await file.delete();

      // Удаляем из кэша и SharedPreferences
      _customArtCache.remove(trackId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('custom_art_$trackId');
    } catch (e) {
      debugPrint('[ArtworkHelper.removeCustomArtwork] Failed: $e');
    }
  }

  /// Удаляет кастомную обложку плейлиста (только файл)
  static Future<void> removePlaylistCover(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[ArtworkHelper.removePlaylistCover] Failed: $e');
    }
  }
}

bool isWideArt(dynamic item) {
  String sourceId;
  String? artworkUrl;
  String? trackId;

  if (item is Track) {
    sourceId = item.sourceId;
    artworkUrl = item.artworkUrl;
    trackId = item.id;
  } else if (item is MediaItem) {
    sourceId = item.extras?['sourceId'] as String? ?? '';
    artworkUrl = item.artUri?.toString();
    trackId = item.extras?['trackId'] as String? ?? item.id;
  } else {
    throw ArgumentError(
      'isWideArt принимает только Track или MediaItem, получен: ${item.runtimeType}',
    );
  }

  // 1. Если для трека установлена локальная кастомная обложка — она ВСЕГДА квадратная (1:1)!
  if (ArtworkHelper.getCustomArtworkSync(trackId) != null) {
    return false;
  }

  // 2. Стандартная проверка для YouTube
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