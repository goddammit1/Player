// lib/sources/playback_source.dart
//
// Нейтральное описание того, ЧТО играть, без привязки к аудиодвижку.
//
// Источники ([TrackSource.createPlaybackSource]) возвращают [PlaybackSource],
// а бэкенд воспроизведения решает, КАК это играть: мобильный (just_audio)
// превращает его ровно в те же объекты, что раньше создавали источники
// (`LockCachingAudioSource`, `SoulseekStreamAudioSource`, `AudioSource.uri`),
// десктопный (media_kit) — в URL локального прокси или путь к файлу.

/// Что играть: локальный файл, удалённый поток, HLS или растущий файл.
sealed class PlaybackSource {
  const PlaybackSource();
}

/// Готовый файл на диске: офлайн-кэш, завершённые загрузки Soulseek.
final class LocalFile extends PlaybackSource {
  const LocalFile(this.path);

  final String path;

  @override
  String toString() => 'LocalFile($path)';
}

/// Прогрессивный HTTP-поток (muzmo / soundcloud mp3 / youtube).
///
/// [cachePath] — куда записать файл по мере стриминга (аудиокэш
/// [YoutubeCache]); null — играть без записи в кэш.
final class RemoteStream extends PlaybackSource {
  const RemoteStream(
    this.uri, {
    this.headers = const {},
    this.cachePath,
  });

  final Uri uri;
  final Map<String, String> headers;
  final String? cachePath;

  @override
  String toString() => 'RemoteStream($uri, cache: $cachePath)';
}

/// HLS-манифест (soundcloud): кэширования нет, играет сам движок.
final class Hls extends PlaybackSource {
  const Hls(this.uri, {this.headers = const {}});

  final Uri uri;
  final Map<String, String> headers;

  @override
  String toString() => 'Hls($uri)';
}

/// Файл, который ещё скачивается (Soulseek: `.part` во время загрузки).
///
/// Читатель отдаёт уже записанные байты и ждёт прироста файла.
/// [completion] завершается финальным путём после переименования `.part`
/// или ошибкой загрузки — она обрывает текущие и будущие чтения.
final class GrowingFile extends PlaybackSource {
  const GrowingFile({
    required this.partPath,
    required this.totalBytes,
    required this.contentType,
    required this.completion,
  });

  final String partPath;

  /// Заявленный размер файла: длина источника для плеера.
  final int totalBytes;
  final String contentType;
  final Future<String> completion;

  @override
  String toString() => 'GrowingFile($partPath, $totalBytes bytes)';
}

/// MIME-тип аудиофайла по расширению.
String audioContentTypeFor(String extension) {
  switch (extension.toLowerCase()) {
    case 'mp3':
      return 'audio/mpeg';
    case 'flac':
      return 'audio/flac';
    case 'ogg':
    case 'opus':
      return 'audio/ogg';
    case 'm4a':
    case 'aac':
    case 'alac':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'webm':
      return 'audio/webm';
    default:
      return 'application/octet-stream';
  }
}
