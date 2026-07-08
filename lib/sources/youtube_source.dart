import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';
import 'track_source.dart';
import '../core/youtube_cache.dart';

// ignore: avoid_print
void _ytLog(String msg) => print('[YoutubeSource] $msg');

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
    // Добавляем "music" в конец запроса — YouTube лучше ранжирует музыкальные видео
    final musicQuery = '$query music';
    final results = await _yt.search.search(musicQuery);

    // Не оставляем «только официальные релизы» — это режет почти всё.
    // Наоборот: пропускаем любую музыку и выкидываем лишь ЯВНО
    // немузыкальные ролики по эвристикам (длительность, прямые эфиры,
    // ключевые слова в названии). Описание не догружаем — это медленно
    // и для отсева мусора не требуется.
    //
    // ВАЖНО: битрейт здесь НЕ резолвим — getManifest медленный (3–8 с
    // на трек) и заметно тормозит поиск. Битрейт получаем лениво в
    // «Деталях трека» через [resolveBitrate].
    final scored = <_ScoredVideo>[];
    for (final v in results) {
      if (_isLikelyNonMusic(v)) continue;
      scored.add(_ScoredVideo(video: v, score: _musicQualityScore(v)));
    }

    // Сортируем: official/Topic выше, мусор ниже
    scored.sort((a, b) => b.score.compareTo(a.score));

    final music = <Track>[];
    for (final s in scored) {
      music.add(_videoToTrack(s.video));
      if (music.length >= limit) break;
    }
    return music;
  }

  /// Ленивый битрейт для «Деталей трека»: берём из манифеста выбранной
  /// аудиодорожки. Результат кэшируется в [_streamInfoCache], так что
  /// последующее воспроизведение не делает повторный getManifest.
  @override
  Future<int?> resolveBitrate(Track track) async {
    try {
      final info = await _getStreamInfo(track.id);
      return info.bitrate.kiloBitsPerSecond.round();
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ФИЛЬТРАЦИЯ И РАНЖИРОВАНИЕ
  // ═══════════════════════════════════════════════════════════════════

  /// Стоп-слова в названии, характерные для НЕмузыкальных видео:
  /// обзоры, влоги, летсплеи, подкасты, интервью, туториалы и т.п.
  static final RegExp _nonMusicTitle = RegExp(
    r'\b('
    r'обзор|распаковка|влог|vlog|летсплей|let.?s\s*play|gameplay|'
    r'прохождение|стрим|stream|podcast|подкаст|интервью|interview|'
    r'tutorial|туториал|урок|review|reaction|реакция|'
    r'трейлер|trailer|новости|news|разбор|лекция|lecture|'
    r'how\s*to|unboxing|top\s*\d+|compilation|mixtape\s*review|'
    r'album\s*review|track\s*by\s*track|listening\s*party|'
    r'first\s*reaction|reacts\s*to|breakdown|analysis|'
    r'news|новости|шоу|show|talk\s+show|ток\s+шоу|stand\s*up|'
    r'comedy|комедия|prank|пранк|challenge|челлендж|'
    r'asmr|mukbang|мукбанг|q&a|вопрос\s*ответ|'
    r'behind\s*the\s*scenes|bts|making\s*of|documentary|документалка'
    r')\b',
    caseSensitive: false,
  );

  /// Возвращает true, если видео ЯВНО не музыка и его стоит исключить.
  ///
  /// Опираемся только на данные из результатов поиска (без описания):
  ///   • прямые трансляции (`isLive`) — не треки;
  ///   • слишком короткие (< 30 сек) — тизеры/реклама/shorts;
  ///   • слишком длинные (> 20 мин) — подкасты, стримы, лекции;
  ///   • 10-20 мин без official канала — скорее подкаст;
  ///   • немузыкальные стоп-слова в названии.
  /// Всё остальное считаем музыкой и пропускаем.
  bool _isLikelyNonMusic(Video v) {
    if (v.isLive) return true;

    final d = v.duration;
    if (d == null) return false;

    // Слишком короткое — тизер/реклама/Shorts
    if (d < const Duration(seconds: 30)) return true;

    // Слишком длинное — подкасты, стримы, лекции
    if (d > const Duration(minutes: 20)) return true;

    // 10-20 мин без official канала — скорее подкаст
    if (d > const Duration(minutes: 10) && !_isOfficialMusicChannel(v.author)) {
      return true;
    }

    // Shorts — почти никогда не полноценные треки
    if (_isShorts(v)) return true;

    if (_nonMusicTitle.hasMatch(v.title)) return true;

    return false;
  }

  /// Проверяет, является ли видео YouTube Shorts
  bool _isShorts(Video v) {
    final d = v.duration;
    if (d == null || d > const Duration(seconds: 60)) return false;
    final title = v.title.toLowerCase();
    return title.contains('#shorts') || title.contains('shorts');
  }

  /// Проверяет, является ли канал официальным музыкальным
  bool _isOfficialMusicChannel(String author) {
    final a = author.toLowerCase();
    return a.contains('vevo') ||
           a.contains('official') ||
           a.contains(' - topic');
  }

  /// Score «музыкальности» — чем выше, тем более вероятно качественный трек
  int _musicQualityScore(Video v) {
    int score = 0;
    final author = v.author.toLowerCase();
    final title = v.title.toLowerCase();

    // YouTube Music auto-generated = +3 (лучший источник)
    if (author.contains(' - topic')) score += 3;

    // VEVO = +2
    if (author.contains('vevo')) score += 2;

    // Official channel = +1
    if (author.contains('official')) score += 1;

    // Title содержит музыкальные маркеры = +1
    if (title.contains('official') ||
        title.contains('audio') ||
        title.contains('lyrics') ||
        title.contains('video')) {
      score += 1;
    }

    // Длительность в «идеальном» диапазоне 2-6 мин = +1
    final d = v.duration;
    if (d != null && d >= const Duration(minutes: 2) && d <= const Duration(minutes: 6)) {
      score += 1;
    }

    return score;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ОЧИСТКА МЕТАДАННЫХ
  // ═══════════════════════════════════════════════════════════════════

  /// Очищает title от типичных YouTube-суффиксов
  String _cleanTitle(String title) {
    return title
      .replaceAll(RegExp(r'\s*\(official\s*(music\s*)?video\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\(official\s*audio\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\(lyric\s*video\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\(audio\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\(visualizer\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\[official\s*(music\s*)?video\]', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\[official\s*audio\]', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*-\s*audio\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*-\s*official\s*video\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*-\s*official\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\|\s*official\s*video\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*【[^】]*】'), '')
      .replaceAll(RegExp(r'^\s*【[^】]*】\s*'), '')
      .trim();
  }

  /// Убирает " - Topic" из названия канала
  String _cleanArtist(String author) {
    return author.replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '').trim();
  }

  Track _videoToTrack(Video v, {int? bitrateKbps}) {
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
      title: _cleanTitle(v.title),
      artist: _cleanArtist(v.author),
      duration: v.duration,
      artworkUrl: thumb,
      // qualityScore — реальный битрейт в kbps (используется для
      // сортировки), qualityLabel — он же для показа в UI.
      qualityScore: bitrateKbps,
      qualityLabel: bitrateKbps != null ? '$bitrateKbps kbps' : null,
    );
  }

  /// Returns a cached or freshly fetched audio-only stream info for the
  /// given YouTube video id.
  Future<AudioOnlyStreamInfo> _getStreamInfo(String videoId) async {
    final cached = _streamInfoCache[videoId];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.info;
    }

    // Пробуем несколько стратегий по порядку. YouTube периодически
    // блокирует отдельные client-ы, поэтому фолбэк критически важен.
    // Сначала пробуем дефолт библиотеки (без указания клиентов),
    // затем конкретные клиенты по одному.
    final strategies = <List<YoutubeApiClient>?>[
      null, // дефолт библиотеки
      [YoutubeApiClient.ios],
      [YoutubeApiClient.mediaConnect],
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.safari],
      [YoutubeApiClient.tv],
    ];

    StreamManifest? manifest;
    for (final clients in strategies) {
      try {
        final label = clients?.map((c) => c.toString()).join(',') ?? 'default';
        _ytLog('Trying client=$label for $videoId');
        if (clients != null) {
          manifest = await _yt.videos.streamsClient.getManifest(
            videoId,
            ytClients: clients,
          );
        } else {
          manifest = await _yt.videos.streamsClient.getManifest(videoId);
        }
        if (manifest.audioOnly.isNotEmpty) {
          _ytLog('Got ${manifest.audioOnly.length} audio streams '
              'via $label for $videoId');
          break;
        }
        _ytLog('$label returned 0 audio streams for $videoId');
      } catch (e) {
        final label = clients?.map((c) => c.toString()).join(',') ?? 'default';
        _ytLog('$label failed for $videoId: $e');
        continue;
      }
    }

    if (manifest == null || manifest.audioOnly.isEmpty) {
      throw Exception('No audio streams found for video $videoId '
          'after trying all YouTube API clients');
    }

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

/// Вспомогательный класс для ранжирования видео по качеству
class _ScoredVideo {
  final Video video;
  final int score;
  _ScoredVideo({required this.video, required this.score});
}

class _CachedStreamInfo {
  _CachedStreamInfo({required this.info, required this.expiresAt});
  final AudioOnlyStreamInfo info;
  final DateTime expiresAt;
}
