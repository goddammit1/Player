// lib/core/track_actions.dart
//
// Действия над треком без UI: кэш-статус, загрузка для офлайна, удаление
// загрузки, папка пира Soulseek, Play next. Общие для шторки настроек трека
// (track_settings_sheet.dart), десктопного контекстного меню и вкладки
// «Track» панели очереди.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/track.dart';
import '../sources/soulseek_models.dart';
import '../sources/soulseek_platform_channel.dart';
import '../sources/soulseek_source.dart';
import '../sources/source_registry.dart';
import 'player_service_interface.dart';
import 'youtube_cache.dart';

/// Состояние офлайн-копии трека.
enum TrackCacheState { notCached, downloading, cached }

class TrackCacheStatus {
  const TrackCacheStatus(this.state, {this.progress, this.transfer});

  static const notCached = TrackCacheStatus(TrackCacheState.notCached);
  static const cached = TrackCacheStatus(TrackCacheState.cached);

  final TrackCacheState state;

  /// 0..1 для [TrackCacheState.downloading]; null — прогресс неизвестен.
  final double? progress;

  /// Soulseek: снимок идущего трансфера (скорость, состояние у пира).
  final SoulseekTransferInfo? transfer;

  bool get isCached => state == TrackCacheState.cached;
  bool get isDownloading => state == TrackCacheState.downloading;
}

/// Идущая загрузка стримингового трека в [YoutubeCache].
class _ActiveDownload {
  late final Future<void> future;
  double? progress;
  final listeners = <void Function(double progress)>[];
}

abstract final class TrackActions {
  /// Загрузки стриминговых треков по [cacheId]: повторный запрос (меню,
  /// вкладка «Track», шторка) присоединяется к идущей, а не пишет тот же
  /// `.part` второй раз.
  static final Map<String, _ActiveDownload> _activeDownloads = {};

  static final StreamController<String> _cacheChanges =
      StreamController<String>.broadcast(sync: false);

  /// `globalId` трека, у которого начали / закончили загрузку или удалили
  /// офлайн-копию: открытые виджеты статуса перечитывают его.
  static Stream<String> get cacheChanges => _cacheChanges.stream;

  static void _notifyCacheChanged(Track track) =>
      _cacheChanges.add(track.globalId);

  /// Id файла трека в [YoutubeCache] (стриминговые источники).
  static String cacheId(Track track) =>
      YoutubeCache.cacheIdFor(sourceId: track.sourceId, trackId: track.id);

  /// PLAYER-DL-01: Soulseek-источник, если трек из Soulseek.
  static SoulseekSource? soulseekSource(Track track) {
    if (track.sourceId != SoulseekSource.sourceId) return null;
    return SourceRegistry.instance.get(SoulseekSource.sourceId)
        as SoulseekSource?;
  }

  /// PLAYER-DL-01: cacheKey для нативного кэша Soulseek (null — трек не
  /// Soulseek или данных недостаточно → путь через YoutubeCache).
  static String? soulseekCacheKey(Track track) =>
      soulseekSource(track)?.cacheKeyFor(track);

  /// downloadId нативной загрузки Soulseek (null — трек не Soulseek). После
  /// перехода ручной загрузки к запасному пиру — его загрузка.
  static String? soulseekDownloadId(Track track) =>
      soulseekSource(track)?.activeDownloadIdFor(track);

  /// Soulseek-трек с известным пиром и каталогом — папку можно открыть.
  static bool soulseekFolderAvailable(Track track) {
    if (soulseekSource(track) == null) return false;
    final remote = track.extra['remoteFilename'] as String?;
    return track.extra['peerUsername'] is String &&
        remote != null &&
        SoulseekSource.folderOf(remote).isNotEmpty;
  }

  /// Source-aware проверка: Soulseek-треки живут в нативном кэше, а не в
  /// [YoutubeCache]. Для Soulseek учитывается активная загрузка.
  static Future<TrackCacheStatus> cacheStatus(Track track) async {
    try {
      final source = soulseekSource(track);
      final downloadId = soulseekDownloadId(track);
      if (source != null && downloadId != null) {
        if ((await source.cachedKeysFor(track)).isNotEmpty) {
          return TrackCacheStatus.cached;
        }
        final info = await source.getTransfer(downloadId);
        // Пауза — тоже живая загрузка: её возобновляют, а не начинают
        // заново. Конец — только completed / cancelled / failed.
        if (info != null && !info.state.isTerminal) {
          return TrackCacheStatus(
            TrackCacheState.downloading,
            progress: info.progress,
            transfer: info,
          );
        }
        return TrackCacheStatus.notCached;
      }
      final id = cacheId(track);
      final active = _activeDownloads[id];
      if (active != null) {
        return TrackCacheStatus(
          TrackCacheState.downloading,
          progress: active.progress,
        );
      }
      return await YoutubeCache.instance.hasFile(id)
          ? TrackCacheStatus.cached
          : TrackCacheStatus.notCached;
    } catch (_) {
      return TrackCacheStatus.notCached;
    }
  }

  /// Transfer-события нативной загрузки этого трека (пустой поток — трек не
  /// Soulseek).
  static Stream<SoulseekTransferEvent> soulseekTransfers(Track track) {
    final source = soulseekSource(track);
    if (source == null) return const Stream.empty();
    return source.transferEventsFor(track);
  }

  /// Скачивает трек для офлайна.
  ///
  /// Стриминговые источники: файл качается в `.part`, затем атомарно
  /// публикуется в [YoutubeCache] и закрепляется. Future завершается после
  /// публикации.
  ///
  /// Soulseek: нативная загрузка (prefetch → startDownload с dedupe по
  /// downloadId) — одна загрузка, корректное расширение файла. Future
  /// завершается после старта; завершение — в [soulseekTransfers].
  static Future<void> download(
    Track track, {
    void Function(double progress)? onProgress,
  }) async {
    final soulseek = soulseekSource(track);
    if (soulseek != null && soulseekCacheKey(track) != null) {
      await soulseek.startManualDownload(track);
      _notifyCacheChanged(track);
      return;
    }

    final id = cacheId(track);
    final existing = _activeDownloads[id];
    if (existing != null) {
      if (onProgress != null) existing.listeners.add(onProgress);
      return existing.future;
    }
    final active = _ActiveDownload();
    if (onProgress != null) active.listeners.add(onProgress);
    _activeDownloads[id] = active;
    active.future = _downloadStreaming(track, id, (progress) {
      active.progress = progress;
      for (final listener in List.of(active.listeners)) {
        listener(progress);
      }
    }).whenComplete(() {
      if (identical(_activeDownloads[id], active)) _activeDownloads.remove(id);
      _notifyCacheChanged(track);
    });
    _notifyCacheChanged(track);
    return active.future;
  }

  static Future<void> _downloadStreaming(
    Track track,
    String id,
    void Function(double progress) onProgress,
  ) async {
    final source = SourceRegistry.instance.require(track.sourceId);
    final url = await source.resolveStreamUrl(track);
    final cacheFile = await YoutubeCache.instance.fileFor(id, extension: 'mp3');
    final partPath = '${cacheFile.path}.part';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    try {
      await dio.download(
        url,
        partPath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress((received / total).clamp(0.0, 1.0));
        },
      );
      await File(partPath).rename(cacheFile.path);
    } catch (_) {
      try {
        final part = File(partPath);
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      dio.close();
    }

    await YoutubeCache.instance.pin(id);
    await YoutubeCache.instance.registerTrack(track);
  }

  /// Удаляет офлайн-копию трека.
  static Future<void> deleteCache(Track track) async {
    // PLAYER-DL-01: native-delete для Soulseek (removeCache + forgetCacheKey,
    // паттерн кэш-листа) — YoutubeCache.evict не знает про native-кэш.
    final soulseek = soulseekSource(track);
    final cacheKey = soulseekCacheKey(track);
    if (soulseek != null && cacheKey != null) {
      try {
        // Копии у всех источников трека: файл мог прийти от запасного пира.
        for (final key in {cacheKey, ...await soulseek.cachedKeysFor(track)}) {
          await SoulseekPlatformChannel.instance.removeCache(key);
          soulseek.forgetCacheKey(key);
        }
      } on UnsupportedError {
        // Soulseek недоступен на платформе — native-кэша нет.
      }
      _notifyCacheChanged(track);
      return;
    }
    await YoutubeCache.instance.evict(cacheId(track));
    _notifyCacheChanged(track);
  }

  /// Ставит трек следующим после текущего.
  static Future<void> playNext(PlayerServiceInterface player, Track track) =>
      player.insertToQueue(track);
}
