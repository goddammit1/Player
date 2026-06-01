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

  /// Закрыть ресурсы (HTTP-клиенты и т.п.).
  Future<void> dispose() async {}
}
