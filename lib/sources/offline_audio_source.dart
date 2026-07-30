import 'package:just_audio/just_audio.dart';

import '../core/youtube_cache.dart';
import '../models/track.dart';

/// Хелпер для офлайн-воспроизведения кэшированных треков.
///
/// Если трек уже сохранён в дисковом кэше [YoutubeCache], возвращает
/// [AudioSource.uri] с file:// URL, чтобы just_audio играл локальный
/// файл и не лез в сеть. В офлайне это единственный способ
/// воспроизвести трек, не пытаясь зарезолвить временный stream URL.
Future<AudioSource?> createOfflineAudioSource(Track track) async {
  final cacheId = YoutubeCache.cacheIdFor(
    sourceId: track.sourceId,
    trackId: track.id,
  );
  final file = await YoutubeCache.instance.findFile(cacheId);
  if (file != null) {
    return AudioSource.uri(Uri.file(file.path));
  }
  return null;
}
