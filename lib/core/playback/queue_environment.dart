// lib/core/playback/queue_environment.dart
//
// Всё, что ядру очереди ([QueueEngine]) нужно от остального приложения:
// источники, кэш, обложки, история, настройки и сохранённая сессия.
// Шов для юнит-тестов ядра: в тестах подменяется фейком, в приложении —
// [DefaultQueueEnvironment] поверх синглтонов.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart'
    show ImageConfiguration, ImageStreamListener, Size;

import '../../models/track.dart';
import '../../sources/artwork_provider.dart';
import '../../sources/playback_source.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../../sources/soulseek_source.dart';
import '../../sources/source_registry.dart';
import '../artwork_helper.dart';
import '../cache_evictor.dart';
import '../database/app_database.dart';
import '../player_conversions.dart';
import '../repositories/history_repository.dart';
import '../repositories/playlist_repository.dart';
import '../youtube_cache.dart';

/// Сохранённая сессия плеера.
typedef SavedSession = ({List<Track> queue, int currentIndex, int positionMs});

abstract class QueueEnvironment {
  /// Что играть для трека (см. [TrackSource.createPlaybackSource]).
  Future<PlaybackSource> resolve(Track track);

  /// «Прогрев» следующего трека очереди.
  Future<void> prefetch(Track track);

  /// Инвалидирует кэш трека перед повторной попыткой после ошибки.
  Future<void> evictCache(Track track);

  /// Есть ли смысл повторить воспроизведение трека после [error]. Нет —
  /// если источник отказал окончательно (пир не отдаёт файл): повтор
  /// получит тот же отказ.
  bool isRetryable(Object error);

  /// Защищает файл играющего трека от эвикта и очистки кэша.
  void protectCache(Track track);

  /// Нужно ли перезапросить обложку трека (нет своей, провайдерская
  /// с TTL или мёртвая ссылка на удалённую кастомную).
  bool needsArtworkRefresh(Track track);

  /// Актуальный URL обложки (источник → Genius/iTunes); null — не нашли.
  Future<String?> fetchArtworkUrl(Track track);

  /// Прогревает картинку в кэше изображений.
  void precacheArtwork(String url);

  /// Сохраняет новую обложку трека в плейлистах и истории.
  void persistArtwork(String globalId, String url);

  /// Удаляет файл кастомной обложки трека.
  Future<void> removeCustomArtwork(String trackId);

  Future<void> addToHistory(Track track);

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);

  Future<SavedSession?> loadSession();
  Future<void> saveSession({
    required List<Track> queue,
    required int currentIndex,
    required int positionMs,
  });
}

class DefaultQueueEnvironment implements QueueEnvironment {
  const DefaultQueueEnvironment();

  @override
  Future<PlaybackSource> resolve(Track track) =>
      SourceRegistry.instance.require(track.sourceId).createPlaybackSource(track);

  @override
  Future<void> prefetch(Track track) =>
      SourceRegistry.instance.require(track.sourceId).prefetch(track);

  /// Source-aware (см. [evictTrackCache]): для Soulseek — нативный кэш +
  /// сброс Dart-индекса cache keys, для остальных — YoutubeCache.evict.
  @override
  Future<void> evictCache(Track track) => evictTrackCache(
        track,
        removeSoulseekCache: (cacheKey) =>
            SoulseekPlatformChannel.instance.removeCache(cacheKey),
        forgetSoulseekCacheKey: (cacheKey) {
          final source = SourceRegistry.instance.get(SoulseekSource.sourceId);
          if (source is SoulseekSource) source.forgetCacheKey(cacheKey);
        },
        evictYoutubeCache: (cacheId) => YoutubeCache.instance.evict(cacheId),
      );

  @override
  bool isRetryable(Object error) =>
      error is! SoulseekException || error.retryable;

  @override
  void protectCache(Track track) => YoutubeCache.instance.setProtectedId(
        YoutubeCache.cacheIdFor(sourceId: track.sourceId, trackId: track.id),
      );

  /// Если у трека уже есть «родная» обложка источника (SoundCloud
  /// `sndcdn.com`, YouTube `i.ytimg.com`, локальный файл) — не трогаем её:
  /// она стабильна, и перезапрос через Genius/iTunes может только заменить
  /// её на чужую картинку или ничего не дать.
  @override
  bool needsArtworkRefresh(Track track) {
    final existing = track.artworkUrl;
    if (existing == null || existing.isEmpty) return true;
    if (ArtworkProvider.isProviderArtworkUrl(existing)) return true;
    // Ссылка на кастомную обложку, файл которой удалён («Clear all
    // cache»), — мёртвая: перезапрашиваем оригинал из источника/провайдера.
    return existing.contains('custom_artworks') &&
        ArtworkHelper.getCustomArtworkSync(track.id) == null;
  }

  /// 1. Если у трека нет обложки — пробуем восстановить «родную» из
  ///    источника (SoundCloud по ID и т.п.), т.к. Genius/iTunes её не знают.
  /// 2. Иначе — Genius/iTunes (с TTL-кэшем, устаревший URL перезапрашивается).
  ///
  /// Обложка играющего трека обходит очередь фонового обогащения выдачи
  /// ([ArtworkProvider.runPrioritized]).
  @override
  Future<String?> fetchArtworkUrl(Track track) =>
      ArtworkProvider.runPrioritized(() => _fetchArtworkUrl(track));

  Future<String?> _fetchArtworkUrl(Track track) async {
    final existing = track.artworkUrl;
    if (existing == null || existing.isEmpty) {
      try {
        final url = await SourceRegistry.instance
            .get(track.sourceId)
            ?.resolveArtwork(track);
        if (url != null && url.isNotEmpty) return url;
      } catch (_) {
        // Падение источника не мешает фолбэку на Genius/iTunes.
      }
    }
    return ArtworkProvider.instance
        .findArtwork(track.artist, track.title, preferredSize: 600);
  }

  @override
  void precacheArtwork(String url) {
    unawaited(_precacheImageWithSize(url, 200).catchError((_) {}));
  }

  Future<void> _precacheImageWithSize(String url, int size) async {
    final provider = CachedNetworkImageProvider(url);
    final config = ImageConfiguration(
      size: Size(size.toDouble(), size.toDouble()),
    );
    final stream = provider.resolve(config);
    final completer = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, _) {
        imageInfo.image.dispose();
        // NEW-1: слушатель стреляет на каждый кадр (мультифреймовые
        // изображения) — guard от «Bad state: Future already completed».
        if (!completer.isCompleted) completer.complete();
      },
      onError: (exception, stackTrace) {
        // Error может прийти после успешного кадра — игнорируем.
        if (!completer.isCompleted) {
          completer.completeError(exception, stackTrace);
        }
      },
    );
    stream.addListener(listener);
    try {
      await completer.future;
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  void persistArtwork(String globalId, String url) {
    unawaited(PlaylistRepository.instance.updateTrackArtwork(globalId, url));
    unawaited(HistoryRepository.instance.updateTrackArtwork(globalId, url));
  }

  @override
  Future<void> removeCustomArtwork(String trackId) =>
      ArtworkHelper.removeCustomArtwork(trackId);

  @override
  Future<void> addToHistory(Track track) =>
      HistoryRepository.instance.add(track);

  @override
  Future<String?> getSetting(String key) =>
      AppDatabase.instance.getSetting(key);

  @override
  Future<void> setSetting(String key, String value) =>
      AppDatabase.instance.setSetting(key, value);

  @override
  Future<SavedSession?> loadSession() =>
      AppDatabase.instance.loadPlaybackSession();

  @override
  Future<void> saveSession({
    required List<Track> queue,
    required int currentIndex,
    required int positionMs,
  }) =>
      AppDatabase.instance.savePlaybackSession(
        queueRows: queue.map(PlayerConversions.trackToRow).toList(),
        currentIndex: currentIndex,
        positionMs: positionMs,
      );
}
