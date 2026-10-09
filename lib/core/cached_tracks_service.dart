// lib/core/cached_tracks_service.dart
//
// Единый взгляд на два аудио-кэша приложения:
//  - стриминговый (`YoutubeCache`, `yt_audio_cache`): muzmo, SoundCloud,
//    легаси YouTube. Наличие трека — файл на диске, метаданные — таблица
//    `audio_cache_index`, а для файлов, закэшированных до появления индекса,
//    — поиск по плейлистам и истории;
//  - Soulseek (нативный кэш, только Android): записи нативной БД через
//    MethodChannel.
//
// Хранилища и их лимиты остаются раздельными, сервис только сводит их в
// один список и раздаёт действия (удалить, закрепить, очистить) по
// принадлежности трека.

import 'dart:async';

import '../models/track.dart';
import '../sources/soulseek_models.dart';
import '../sources/soulseek_platform_channel.dart';
import '../sources/soulseek_source.dart';
import '../sources/source_registry.dart';
import 'database/app_database.dart';
import 'database/audio_cache_index_dao.dart';
import 'repositories/history_repository.dart';
import 'repositories/playlist_repository.dart';
import 'youtube_cache.dart';

/// Действие с кэшем не выполнено; [message] — для показа пользователю.
class CacheActionException implements Exception {
  const CacheActionException(this.message);

  final String message;

  @override
  String toString() => 'CacheActionException: $message';
}

/// Хранилище, в котором лежит кэшированный трек.
enum CacheStore { streaming, soulseek }

/// Трек в одном из аудио-кэшей.
class CachedTrack {
  const CachedTrack({
    required this.key,
    required this.store,
    required this.track,
    required this.sizeBytes,
    required this.cachedAt,
    required this.pinned,
  });

  /// Ключ в хранилище: cache id стримингового кэша или cacheKey Soulseek.
  final String key;
  final CacheStore store;
  final Track track;
  final int sizeBytes;

  /// Когда трек попал в кэш; null — неизвестно.
  final DateTime? cachedAt;

  /// Закреплён (ручная загрузка): LRU-эвикция его не трогает.
  final bool pinned;

  CachedTrack copyWith({bool? pinned}) => CachedTrack(
        key: key,
        store: store,
        track: track,
        sizeBytes: sizeBytes,
        cachedAt: cachedAt,
        pinned: pinned ?? this.pinned,
      );
}

/// Суммарная занятость кэшей.
class CacheUsage {
  const CacheUsage({
    required this.streamingBytes,
    required this.soulseekBytes,
    required this.trackCount,
  });

  factory CacheUsage.of(List<CachedTrack> tracks) {
    var streaming = 0;
    var soulseek = 0;
    for (final t in tracks) {
      switch (t.store) {
        case CacheStore.streaming:
          streaming += t.sizeBytes;
        case CacheStore.soulseek:
          soulseek += t.sizeBytes;
      }
    }
    return CacheUsage(
      streamingBytes: streaming,
      soulseekBytes: soulseek,
      trackCount: tracks.length,
    );
  }

  final int streamingBytes;
  final int soulseekBytes;
  final int trackCount;

  int get totalBytes => streamingBytes + soulseekBytes;
}

typedef SoulseekEntriesLoader = Future<List<SoulseekCacheEntry>> Function();
/// Возвращает false, если нативный кэш файл не удалил.
typedef SoulseekEntryRemover = Future<bool> Function(String cacheKey);
typedef SoulseekEntryPinner = Future<void> Function(
  String cacheKey,
  bool pinned,
);
typedef SoulseekTrackBuilder = Track? Function(SoulseekCacheEntry entry);
typedef AudioCacheIndexLoader = Future<Map<String, AudioCacheIndexEntry>>
    Function();
typedef KnownTracksProvider = Iterable<Track> Function();

/// Сводит стриминговый и Soulseek-кэш в один список треков.
///
/// Зависимости передаются колбэками (как в `cache_evictor.dart`), чтобы
/// тестировать без platform channels и репозиториев; по умолчанию —
/// боевые синглтоны.
class CachedTracksService {
  CachedTracksService({
    YoutubeCache? cache,
    SoulseekEntriesLoader? loadSoulseekEntries,
    SoulseekEntryRemover? removeSoulseekEntry,
    SoulseekEntryPinner? pinSoulseekEntry,
    SoulseekTrackBuilder? soulseekTrackFor,
    AudioCacheIndexLoader? loadIndex,
    KnownTracksProvider? knownTracks,
  })  : _cache = cache ?? YoutubeCache.instance,
        _loadSoulseekEntries = loadSoulseekEntries ?? _defaultSoulseekEntries,
        _removeSoulseekEntry = removeSoulseekEntry ?? _defaultRemoveSoulseek,
        _pinSoulseekEntry = pinSoulseekEntry ?? _defaultPinSoulseek,
        _soulseekTrackFor = soulseekTrackFor ?? _defaultSoulseekTrack,
        _loadIndex = loadIndex ?? AppDatabase.instance.getAudioCacheIndex,
        _knownTracks = knownTracks ?? _defaultKnownTracks;

  final YoutubeCache _cache;
  final SoulseekEntriesLoader _loadSoulseekEntries;
  final SoulseekEntryRemover _removeSoulseekEntry;
  final SoulseekEntryPinner _pinSoulseekEntry;
  final SoulseekTrackBuilder _soulseekTrackFor;
  final AudioCacheIndexLoader _loadIndex;
  final KnownTracksProvider _knownTracks;

  // ═══════════════════════════════════════════════════════════════════
  //  LOAD
  // ═══════════════════════════════════════════════════════════════════

  /// Все кэшированные треки обоих хранилищ, новые сверху (треки без даты
  /// — в конце). При равных датах сохраняется исходный порядок хранилищ:
  /// `List.sort` нестабилен.
  Future<List<CachedTrack>> loadAll() async {
    final results = await Future.wait([_loadStreaming(), _loadSoulseek()]);
    final all = [...results[0], ...results[1]];
    final order = {for (var i = 0; i < all.length; i++) all[i]: i};
    all.sort((a, b) {
      final byDate = _byCachedAtDesc(a, b);
      return byDate != 0 ? byDate : order[a]!.compareTo(order[b]!);
    });
    return all;
  }

  static int _byCachedAtDesc(CachedTrack a, CachedTrack b) {
    final da = a.cachedAt;
    final db = b.cachedAt;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  }

  Future<List<CachedTrack>> _loadStreaming() async {
    final files = await _cache.listAudioFiles();

    Map<String, AudioCacheIndexEntry> index;
    try {
      index = await _loadIndex();
    } catch (_) {
      index = const {};
    }

    // Записи индекса без файла (загрузка не завершилась, файл вычистила
    // ОС, гонка с очисткой) — подчищаем, чтобы индекс не рос.
    final fileIds = {for (final f in files) f.cacheId};
    final orphans = index.keys.where((id) => !fileIds.contains(id)).toList();
    if (orphans.isNotEmpty) unawaited(_cache.forgetMissing(orphans));

    Map<String, Track>? known;
    final result = <CachedTrack>[];
    for (final file in files) {
      final indexed = index[file.cacheId];
      Track track;
      DateTime cachedAt;
      if (indexed != null) {
        track = indexed.track;
        cachedAt = indexed.cachedAt;
      } else {
        // Файл закэширован до появления индекса: ищем метаданные в
        // плейлистах/истории и дописываем индекс, чтобы не зависеть от
        // них в будущем (историю могут очистить).
        known ??= _knownTracksByCacheId();
        final found = known[file.cacheId];
        cachedAt = file.modified;
        if (found != null) {
          track = found;
          unawaited(_cache.registerTrack(found, cachedAt: cachedAt));
        } else {
          track = _placeholderTrack(file.cacheId);
        }
      }
      result.add(CachedTrack(
        key: file.cacheId,
        store: CacheStore.streaming,
        track: track,
        sizeBytes: file.sizeBytes,
        cachedAt: cachedAt,
        pinned: file.pinned,
      ));
    }
    return result;
  }

  Map<String, Track> _knownTracksByCacheId() {
    final map = <String, Track>{};
    try {
      for (final t in _knownTracks()) {
        map.putIfAbsent(
          YoutubeCache.cacheIdFor(sourceId: t.sourceId, trackId: t.id),
          () => t,
        );
      }
    } catch (_) {}
    return map;
  }

  /// Трек без метаданных: играть его можно (офлайн-источник найдёт файл
  /// по id), но название известно только по имени файла.
  static Track _placeholderTrack(String cacheId) {
    final parsed = YoutubeCache.parseCacheId(cacheId);
    return Track(
      id: parsed.trackId,
      sourceId: parsed.sourceId,
      title: cacheId,
      artist: 'Unknown',
    );
  }

  Future<List<CachedTrack>> _loadSoulseek() async {
    List<SoulseekCacheEntry> entries;
    try {
      entries = await _loadSoulseekEntries();
    } catch (_) {
      // Не Android / сервис не привязан — Soulseek-кэша нет.
      return const [];
    }
    final result = <CachedTrack>[];
    for (final entry in entries) {
      if (!entry.complete) continue;
      final track = _soulseekTrackFor(entry);
      if (track == null) continue;
      result.add(CachedTrack(
        key: entry.cacheKey,
        store: CacheStore.soulseek,
        track: track,
        sizeBytes: entry.sizeBytes,
        cachedAt: entry.cachedAt,
        pinned: entry.pinned,
      ));
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ACTIONS
  // ═══════════════════════════════════════════════════════════════════

  /// Удаляет трек из его хранилища. Бросает [CacheActionException],
  /// если файл остался (играющий трек, файл занят, отказ натива).
  Future<void> remove(CachedTrack item) async {
    final removed = switch (item.store) {
      CacheStore.streaming => await _cache.removeTrackFile(item.key),
      CacheStore.soulseek => await _removeSoulseekEntry(item.key),
    };
    if (!removed) {
      throw const CacheActionException(
        "Couldn't remove the track (is it playing?)",
      );
    }
  }

  /// Закрепляет/открепляет трек; возвращает обновлённую запись.
  Future<CachedTrack> setPinned(CachedTrack item, bool pinned) async {
    switch (item.store) {
      case CacheStore.streaming:
        if (pinned) {
          await _cache.pin(item.key);
        } else {
          await _cache.unpin(item.key);
        }
      case CacheStore.soulseek:
        await _pinSoulseekEntry(item.key, pinned);
    }
    return item.copyWith(pinned: pinned);
  }

  /// Очищает Soulseek-кэш целиком (включая закреплённые файлы).
  /// Возвращает число удалённых файлов. Без Soulseek (не Android) — 0;
  /// недоступный сервис или неудалённые файлы — [CacheActionException],
  /// чтобы UI не рапортовал об очистке, которой не было.
  Future<int> clearSoulseek() async {
    final List<SoulseekCacheEntry> entries;
    try {
      entries = await _loadSoulseekEntries();
    } catch (_) {
      throw const CacheActionException('Soulseek cache is unavailable');
    }
    var removed = 0;
    for (final entry in entries) {
      try {
        if (await _removeSoulseekEntry(entry.cacheKey)) removed++;
      } catch (_) {}
    }
    final failed = entries.length - removed;
    if (failed > 0) {
      throw CacheActionException(
        "Couldn't remove $failed Soulseek file(s)",
      );
    }
    final source = SourceRegistry.instance.get(SoulseekSource.sourceId);
    if (source is SoulseekSource) source.clearCacheIndex();
    return removed;
  }

  /// Очищает оба аудио-кэша (обложки не трогает).
  Future<void> clearAudio() async {
    await _cache.clearAudioCache();
    await clearSoulseek();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  DEFAULTS
  // ═══════════════════════════════════════════════════════════════════

  static SoulseekSource? get _soulseekSource {
    final source = SourceRegistry.instance.get(SoulseekSource.sourceId);
    return source is SoulseekSource ? source : null;
  }

  /// Источник истины — нативная БД (P1-каскад); попутно синхронизируется
  /// Dart-индекс cache keys источника.
  static Future<List<SoulseekCacheEntry>> _defaultSoulseekEntries() async {
    final source = _soulseekSource;
    if (source == null || !SoulseekPlatformChannel.instance.isAvailable) {
      return const [];
    }
    await source.refreshCacheIndex();
    return SoulseekPlatformChannel.instance.getCacheEntries();
  }

  static Future<bool> _defaultRemoveSoulseek(String cacheKey) async {
    final removed = await SoulseekPlatformChannel.instance.removeCache(cacheKey);
    if (removed) _soulseekSource?.forgetCacheKey(cacheKey);
    return removed;
  }

  static Future<void> _defaultPinSoulseek(String cacheKey, bool pinned) async {
    await SoulseekPlatformChannel.instance.pinCache(cacheKey, pinned: pinned);
  }

  /// Track с `extra.cacheKey` — мгновенный cache hit в resolveStreamUrl.
  static Track? _defaultSoulseekTrack(SoulseekCacheEntry entry) =>
      _soulseekSource?.trackFromCacheEntry(entry);

  static Iterable<Track> _defaultKnownTracks() sync* {
    for (final playlist in PlaylistRepository.instance.current) {
      yield* playlist.tracks;
    }
    for (final entry in HistoryRepository.instance.current) {
      yield entry.track;
    }
  }
}
