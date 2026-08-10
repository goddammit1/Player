import 'package:just_audio/just_audio.dart';

import '../models/track.dart';

/// Интерфейс, который реализует каждая площадка (YouTube, SoundCloud, VK ...).
///
/// Идея плагинной системы: плеер ничего не знает о конкретных источниках,
/// он лишь оперирует [Track] и обращается к нужному источнику через
/// [SourceRegistry] по [Track.sourceId].
abstract class TrackSource {
  /// Короткий машинный идентификатор источника, например `youtube`.
  String get id;

  /// Человекочитаемое название, например `YouTube Music`.
  String get displayName;

  /// Поиск треков по строке запроса.
  Future<List<Track>> search(String query, {int limit = 20});

  /// Получить прямую ссылку на аудио-стрим для воспроизведения.
  ///
  /// Эти ссылки обычно временные (часы), поэтому резолвятся непосредственно
  /// перед воспроизведением.
  Future<String> resolveStreamUrl(Track track);

  /// Создать готовый [AudioSource] для just_audio.
  ///
  /// Дефолтная реализация — обёртка над [resolveStreamUrl] в [AudioSource.uri].
  /// Источники могут переопределить, чтобы:
  /// - проксировать байты в обход блокировок (см. YoutubeAudioSource),
  /// - использовать DASH/HLS-манифест,
  /// - подмешивать заголовки авторизации и т.п.
  Future<AudioSource> createAudioSource(Track track) async {
    final url = await resolveStreamUrl(track);
    return AudioSource.uri(Uri.parse(url));
  }

  /// Опциональный «прогрев» источника для трека (например, скачать манифест
  /// заранее, чтобы [createAudioSource] позже был мгновенным).
  ///
  /// Дефолтная реализация — no-op. Источники могут переопределить.
  Future<void> prefetch(Track track) async {}

  /// Ленивое получение битрейта аудио в kbps для конкретного трека.
  ///
  /// Вызывается по требованию (например, при открытии «Деталей трека»),
  /// а не при поиске — чтобы не замедлять выдачу. Дефолт — null
  /// (источник не умеет/не знает). Источники переопределяют:
  /// YouTube берёт из манифеста, Muzmo — из размера mp3.
  Future<int?> resolveBitrate(Track track) async => track.qualityScore;

  /// Восстановить «родную» обложку трека из самого источника.
  ///
  /// Нужно для треков, у которых [Track.artworkUrl] потерялся (например,
  /// очистка кэша обложек в старой версии стёрла URL и сохранила null в БД),
  /// а Genius/iTunes такую обложку не знают. Источник может запросить свои
  /// данные по ID трека и вернуть artworkUrl (например, SoundCloud —
  /// GET /tracks/{id}, где лежит artwork_url).
  ///
  /// Дефолт — null (источник не умеет восстанавливать); вызывающий код
  /// в этом случае откатывается на [ArtworkProvider].
  Future<String?> resolveArtwork(Track track) async => null;

  /// Закрыть ресурсы (HTTP-клиенты и т.п.).
  Future<void> dispose() async {}
}
