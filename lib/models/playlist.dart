import 'track.dart';

/// Пользовательский плейлист.
///
/// Хранится как JSON в `SharedPreferences` под ключом `playlists_v1`
/// (см. [PlaylistRepository]). На каждый плейлист сохраняем только
/// метаданные треков и список — стрим-URL'ы резолвятся по требованию
/// через `TrackSource.resolveStreamUrl` точно так же, как и для треков
/// из результатов поиска.
class Playlist {
  /// UUID v4, генерируется при создании.
  final String id;

  /// Имя, которое выводится в UI. Может быть переименовано пользователем.
  final String name;

  /// Треки в порядке добавления. Не уникализируем строго — дубликаты
  /// допускаем, потому что в реальной музыкальной библиотеке так бывает
  /// (например, одна и та же песня в разных версиях).
  final List<Track> tracks;

  /// Опциональная пользовательская обложка. Если `null`, UI рисует
  /// мозаику 2×2 из обложек первых четырёх треков.
  final String? coverCustomUrl;

  /// Время создания (для сортировки «новые сверху»).
  final DateTime createdAt;

  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.coverCustomUrl,
    required this.createdAt,
  });

  Playlist copyWith({
    String? name,
    List<Track>? tracks,
    String? coverCustomUrl,
  }) => Playlist(
    id: id,
    name: name ?? this.name,
    tracks: tracks ?? this.tracks,
    coverCustomUrl: coverCustomUrl ?? this.coverCustomUrl,
    createdAt: createdAt,
  );

  /// Первые 4 непустых артворка — для мозаичной обложки.
  List<String> get coverThumbnails => tracks
      .map((t) => t.artworkUrl)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .take(4)
      .toList();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cover_custom_url': coverCustomUrl,
    'created_at_ms': createdAt.millisecondsSinceEpoch,
    'tracks': tracks.map(_trackToJson).toList(),
  };

  factory Playlist.fromJson(Map<String, dynamic> m) => Playlist(
    id: m['id'] as String,
    name: m['name'] as String,
    coverCustomUrl: m['cover_custom_url'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (m['created_at_ms'] as num).toInt(),
    ),
    tracks: ((m['tracks'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => _trackFromJson(e.cast<String, dynamic>()))
        .toList(),
  );

  static Map<String, dynamic> _trackToJson(Track t) => {
    'id': t.id,
    'source_id': t.sourceId,
    'title': t.title,
    'artist': t.artist,
    'duration_ms': t.duration?.inMilliseconds,
    'artwork_url': t.artworkUrl,
    // extra нужен для muzmo (там лежит streamUrl). Сохраняем только
    // примитивы — большего у нас и нет.
    'extra': t.extra.map((k, v) => MapEntry(k, v?.toString())),
  };

  static Track _trackFromJson(Map<String, dynamic> m) => Track(
    id: m['id'] as String,
    sourceId: m['source_id'] as String,
    title: m['title'] as String,
    artist: m['artist'] as String,
    duration: m['duration_ms'] != null
        ? Duration(milliseconds: (m['duration_ms'] as num).toInt())
        : null,
    artworkUrl: m['artwork_url'] as String?,
    extra: ((m['extra'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v),
    ),
  );
}
