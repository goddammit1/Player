import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';
import 'track_source.dart';
import 'youtube_cache.dart';

/// YouTube-based track source.
///
/// Search and stream resolution both go through `youtube_explode_dart`.
/// For playback we use `just_audio`'s [LockCachingAudioSource]: it
/// downloads the audio into a local file in the background and serves
/// every byte-range request (including seek-back) from that file once
/// it is fully cached. The cached file is reused for repeated playback
/// of the same track and is evicted by [YoutubeCache] (LRU, max 5 files).
class YoutubeSource implements TrackSource {
  final YoutubeExplode _yt = YoutubeExplode();

  /// In-memory cache of resolved audio streams. YouTube manifests / URLs
  /// stay valid for several hours, so there is no reason to call
  /// `getManifest` again within a session — it is the slowest operation
  /// in this source (3–8 seconds typically).
  final Map<String, _CachedStreamInfo> _streamInfoCache = {};
  static const _cacheTtl = Duration(hours: 4);

  @override
  String get id => 'youtube';

  @override
  String get displayName => 'YouTube';

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    final results = await _yt.search.search(query);
    return results.take(limit).map(_videoToTrack).toList();
  }

  Track _videoToTrack(Video v) {
    // Prefer mediumRes — it always exists. maxRes/highRes often return
    // HTTP 404 for older or non-HD videos and just spam the logs.
    final thumb = v.thumbnails.mediumResUrl.isNotEmpty
        ? v.thumbnails.mediumResUrl
        : (v.thumbnails.highResUrl.isNotEmpty
            ? v.thumbnails.highResUrl
            : v.thumbnails.lowResUrl);

    return Track(
      id: v.id.value,
      sourceId: id,
      title: v.title,
      artist: v.author,
      duration: v.duration,
      artworkUrl: thumb,
    );
  }

  /// Returns a cached or freshly fetched audio-only stream info for the
  /// given YouTube video id.
  Future<AudioOnlyStreamInfo> _getStreamInfo(String videoId) async {
    final cached = _streamInfoCache[videoId];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.info;
    }

    // androidVr client returns URLs that ordinary HTTP clients can fetch
    // without YouTube responding with 403. If a particular video ever
    // starts failing — add `YoutubeApiClient.ios` / `mediaConnect` here.
    final manifest = await _yt.videos.streamsClient.getManifest(
      videoId,
      ytClients: [YoutubeApiClient.androidVr],
    );

    final audios = manifest.audioOnly.sortByBitrate();
    // Target the ~96–160 kbps band: solid quality, small initial chunk,
    // fast start. If nothing matches — take the lowest bitrate.
    final preferred = audios.firstWhere(
      (s) =>
          s.bitrate.kiloBitsPerSecond >= 96 &&
          s.bitrate.kiloBitsPerSecond <= 160,
      orElse: () => audios.first,
    );

    _streamInfoCache[videoId] = _CachedStreamInfo(
      info: preferred,
      expiresAt: DateTime.now().add(_cacheTtl),
    );
    return preferred;
  }

  @override
  Future<String> resolveStreamUrl(Track track) async {
    final info = await _getStreamInfo(track.id);
    return info.url.toString();
  }

  /// Wrap the YouTube URL in a [LockCachingAudioSource] so that:
  /// 1) the file is downloaded once and saved on disk,
  /// 2) all subsequent reads (seek-back, replay) are served from the
  ///    local file — no more `416 Range Not Satisfiable` from YouTube
  ///    CDN on seek, no re-download.
  ///
  /// The cache is bounded by [YoutubeCache.maxEntries] (LRU eviction)
  /// so storage doesn't grow unboundedly.
  @override
  Future<AudioSource> createAudioSource(Track track) async {
    final info = await _getStreamInfo(track.id);
    final container = info.container.name.toLowerCase().contains('webm')
        ? 'webm'
        : 'm4a';
    final cacheFile =
        await YoutubeCache.instance.fileFor(track.id, extension: container);

    return LockCachingAudioSource(
      Uri.parse(info.url.toString()),
      // Без headers — just_audio открывает соединение Dart HttpClient'ом
      // напрямую к youtube/googlevideo. Дефолтный User-Agent YouTube
      // принимает (по крайней мере для androidVr URL'ов).
      cacheFile: cacheFile,
      tag: track.globalId,
    );
  }

  /// Pre-warm the manifest for an upcoming track so that the next
  /// `play()` does not have to wait for `getManifest`.
  @override
  Future<void> prefetch(Track track) async {
    try {
      await _getStreamInfo(track.id);
    } catch (_) {
      // Best-effort. If it fails, the next play() will just re-resolve.
    }
  }

  /// Invalidate cached stream info for a specific video. Use this if
  /// playback fails — next `createAudioSource` will fetch a fresh URL.
  void invalidate(String videoId) {
    _streamInfoCache.remove(videoId);
  }

  @override
  Future<void> dispose() async {
    _streamInfoCache.clear();
    _yt.close();
  }
}

class _CachedStreamInfo {
  _CachedStreamInfo({required this.info, required this.expiresAt});
  final AudioOnlyStreamInfo info;
  final DateTime expiresAt;
}
