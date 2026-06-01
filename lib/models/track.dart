/// Унифицированная модель трека.
///
/// Любой источник (YouTube, SoundCloud, VK и т.д.) возвращает [Track]
/// с заполненными базовыми полями. Получение прямой ссылки на стрим
/// делается лениво через [TrackSource.resolveStreamUrl], потому что
/// эти ссылки обычно временные.
class Track {
  /// Уникальный ID в пределах источника (например, video id для YouTube).
  final String id;

  /// Идентификатор источника, например `youtube`, `soundcloud`.
  final String sourceId;

  final String title;
  final String artist;
  final Duration? duration;
  final String? artworkUrl;

  /// Дополнительные данные источника (на случай если нужно вернуть в API).
  final Map<String, dynamic> extra;

  const Track({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.artist,
    this.duration,
    this.artworkUrl,
    this.extra = const {},
  });

  /// Глобальный ID для использования в БД / очереди.
  String get globalId => '$sourceId:$id';

  Track copyWith({
    String? title,
    String? artist,
    Duration? duration,
    String? artworkUrl,
  }) {
    return Track(
      id: id,
      sourceId: sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      extra: extra,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'source_id': sourceId,
        'title': title,
        'artist': artist,
        'duration_ms': duration?.inMilliseconds,
        'artwork_url': artworkUrl,
      };

  factory Track.fromMap(Map<String, dynamic> m) => Track(
        id: m['id'] as String,
        sourceId: m['source_id'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        duration: m['duration_ms'] != null
            ? Duration(milliseconds: m['duration_ms'] as int)
            : null,
        artworkUrl: m['artwork_url'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Track && other.globalId == globalId;

  @override
  int get hashCode => globalId.hashCode;
}
