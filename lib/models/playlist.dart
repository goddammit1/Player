import 'track.dart';

/// Пользовательский плейлист.
///
/// Хранится в SQLite через [AppDatabase] (см. [PlaylistRepository]).
/// На каждый плейлист сохраняем только
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

  /// Ручной порядок треков (режим сортировки «Manual») как список
  /// [Track.globalId] в желаемом порядке.
  ///
  /// `null` — ручной порядок не задан: режим Manual показывает [tracks]
  /// как есть (порядок добавления). Задаётся ТОЛЬКО через drag&drop в
  /// режиме Manual ([PlaylistRepository.reorderTracks]) и никак не влияет
  /// на остальные режимы сортировки: те всегда работают по [tracks].
  ///
  /// Может быть «неполным» относительно [tracks] (трек добавили после
  /// задания порядка или удалили): применение порядка в
  /// [Playlist.applyManualOrder] устойчиво к этому — отсутствующие в списке
  /// треки дописываются в конец в порядке добавления, лишние id
  /// игнорируются.
  final List<String>? manualOrder;

  /// Опциональная пользовательская обложка. Если `null`, UI рисует
  /// мозаику 2×2 из обложек первых четырёх треков.
  final String? coverCustomUrl;

  /// Алиас для [coverCustomUrl] — обратная совместимость.
  String? get coverCustomPath => coverCustomUrl;

  /// Время создания (для сортировки «новые сверху»).
  final DateTime createdAt;

  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.coverCustomUrl,
    this.manualOrder,
    required this.createdAt,
  });

  Playlist copyWith({
    String? name,
    List<Track>? tracks,
    Object? coverCustomUrl = _sentinel,
    Object? manualOrder = _sentinel,
  }) => Playlist(
    id: id,
    name: name ?? this.name,
    tracks: tracks ?? this.tracks,
    coverCustomUrl: identical(coverCustomUrl, _sentinel) ? this.coverCustomUrl : coverCustomUrl as String?,
    manualOrder: identical(manualOrder, _sentinel) ? this.manualOrder : manualOrder as List<String>?,
    createdAt: createdAt,
  );

  static const _sentinel = #sentinel;

  /// Треки в ручном порядке: согласно [manualOrder], недостающие треки —
  /// в конец в порядке добавления, неизвестные id игнорируются.
  ///
  /// Если [manualOrder] не задан — возвращает [tracks] без изменений.
  /// Дубликаты globalId в [tracks] поддерживаются: каждый экземпляр
  /// занимает свою позицию (i-е вхождение id в [manualOrder] получает
  /// i-й трек с этим id).
  List<Track> applyManualOrder() {
    final order = manualOrder;
    if (order == null) return tracks;

    // Индекс → сколько раз globalId уже встречался при раздаче.
    final usedCountById = <String, int>{};
    // globalId → очередь треков с этим id (в порядке добавления).
    final poolById = <String, List<Track>>{};
    for (final t in tracks) {
      poolById.putIfAbsent(t.globalId, () => []).add(t);
    }

    final result = <Track>[];
    final placed = <Track>{}; // identity-набор размещённых экземпляров.
    for (final gid in order) {
      final used = usedCountById[gid] ?? 0;
      final pool = poolById[gid];
      if (pool == null || used >= pool.length) continue; // лишний id.
      final track = pool[used];
      usedCountById[gid] = used + 1;
      result.add(track);
      placed.add(track);
    }
    // Треки, не попавшие в manualOrder (добавлены после задания порядка),
    // — в конец, в порядке добавления.
    for (final t in tracks) {
      if (!placed.contains(t)) result.add(t);
    }
    return result;
  }

  /// Первые 4 непустых артворка — для мозаичной обложки.
  List<String> get coverThumbnails => tracks
      .map((t) => t.artworkUrl)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .take(4)
      .toList();

  /// trackId первых четырёх треков с обложкой — синхронно с [coverThumbnails],
  /// чтобы мозаика могла подставить кастомные обложки отдельных треков.
  List<String> get coverTrackIds => tracks
      .where((t) => t.artworkUrl != null && t.artworkUrl!.isNotEmpty)
      .take(4)
      .map((t) => t.id)
      .toList();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cover_custom_url': coverCustomUrl,
    'created_at_ms': createdAt.millisecondsSinceEpoch,
    // Ручной порядок сериализуем только когда задан — старые версии
    // приложения просто проигнорируют неизвестный ключ.
    if (manualOrder != null) 'manual_order': manualOrder,
    'tracks': tracks.map(_trackToJson).toList(),
  };

  factory Playlist.fromJson(Map<String, dynamic> m) {
    final rawOrder = (m['manual_order'] as List?)
        ?.whereType<String>()
        .toList();
    return Playlist(
      id: m['id'] as String,
      name: m['name'] as String,
      coverCustomUrl: m['cover_custom_url'] as String?,
      manualOrder:
          (rawOrder == null || rawOrder.isEmpty) ? null : rawOrder,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (m['created_at_ms'] as num).toInt(),
      ),
      tracks: ((m['tracks'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => _trackFromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  static Map<String, dynamic> _trackToJson(Track t) => {
    'id': t.id,
    'source_id': t.sourceId,
    'title': t.title,
    'artist': t.artist,
    'duration_ms': t.duration?.inMilliseconds,
    'artwork_url': t.artworkUrl,
    'quality_score': t.qualityScore,
    'quality_label': t.qualityLabel,
    // extra нужен для muzmo (там лежит streamUrl).
    // Сохраняем примитивы как есть: null, строки, числа, булы
    'extra': t.extra.map((k, v) => MapEntry(k, v)),
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
    qualityScore: m['quality_score'] as int?,
    qualityLabel: m['quality_label'] as String?,
    extra: ((m['extra'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v),
    ),
  );
}
