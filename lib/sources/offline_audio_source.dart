import '../core/youtube_cache.dart';
import '../models/track.dart';
import 'playback_source.dart';

/// Хелпер для офлайн-воспроизведения кэшированных треков.
///
/// Если трек уже сохранён в дисковом кэше [YoutubeCache], возвращает
/// [LocalFile], чтобы плеер играл локальный файл и не лез в сеть.
/// В офлайне это единственный способ воспроизвести трек, не пытаясь
/// зарезолвить временный stream URL.
///
/// Фаза 3: кэш передаётся параметром (DI), а не берётся из статического
/// `YoutubeCache.instance`. Дефолт сохранён для обратной совместимости.
Future<LocalFile?> createOfflinePlaybackSource(
  Track track, {
  YoutubeCache? cache,
}) async {
  final cacheId = YoutubeCache.cacheIdFor(
    sourceId: track.sourceId,
    trackId: track.id,
  );
  final file = await (cache ?? YoutubeCache.instance).findFile(cacheId);
  if (file != null) {
    return LocalFile(file.path);
  }
  return null;
}
