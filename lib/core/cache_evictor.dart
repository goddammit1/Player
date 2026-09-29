// lib/core/cache_evictor.dart
//
// Source-aware инвалидация кэша трека при ошибке воспроизведения
// (план исправления CACHE-01, раздел 5.6: recovery плеера source-aware).
//
//  - Soulseek: удаляем файл из нативного кэша через platform channel
//    (removeCache) и сбрасываем Dart-индекс cache keys, чтобы повторный
//    resolve начал новую загрузку.
//  - Остальные источники: прежнее поведение — YoutubeCache.evict.
//
// Логика вынесена из PlayerService в чистую функцию с DI-колбэками,
// чтобы тестировать без реального AudioPlayer и platform channels.

import 'dart:async';

import '../models/track.dart';
import '../sources/soulseek_source.dart';
import 'youtube_cache.dart';

/// Удаляет [cacheKey] из нативного Soulseek-кэша (SoulseekPlatformChannel.removeCache).
typedef SoulseekCacheRemover = FutureOr<void> Function(String cacheKey);

/// Сбрасывает [cacheKey] в Dart-индексе cache keys (SoulseekSource.forgetCacheKey).
typedef SoulseekIndexResetter = void Function(String cacheKey);

/// Инвалидирует [cacheId] в кэше YouTube-подобных источников (YoutubeCache.evict).
typedef YoutubeCacheEvictor = FutureOr<void> Function(String cacheId);

/// Source-aware evict кэша трека перед повторной попыткой воспроизведения.
///
/// Для `src=soulseek` вызывает [removeSoulseekCache] с cacheKey из
/// `track.extra` и сбрасывает Dart-индекс через [forgetSoulseekCacheKey].
/// Отказ нативного удаления (не-Android платформа, сервис недоступен)
/// не должен блокировать retry — ошибка проглатывается, индекс всё равно
/// сбрасывается.
///
/// Для остальных источников вызывает [evictYoutubeCache] с вычисленным
/// YoutubeCache.cacheIdFor.
Future<void> evictTrackCache(
  Track track, {
  required SoulseekCacheRemover removeSoulseekCache,
  required SoulseekIndexResetter forgetSoulseekCacheKey,
  required YoutubeCacheEvictor evictYoutubeCache,
}) async {
  if (track.sourceId == SoulseekSource.sourceId) {
    final cacheKey = track.extra['cacheKey'] as String?;
    if (cacheKey == null || cacheKey.isEmpty) return;

    try {
      await removeSoulseekCache(cacheKey);
    } catch (_) {
      // Не Android / сервис недоступен — retry всё равно перепроверит кэш.
    }
    forgetSoulseekCacheKey(cacheKey);
    return;
  }

  final cacheId = YoutubeCache.cacheIdFor(
    sourceId: track.sourceId,
    trackId: track.id,
  );
  await evictYoutubeCache(cacheId);
}
