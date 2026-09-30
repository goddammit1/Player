// lib/models/track.dart

import 'dart:convert';

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

  /// Оценка качества аудио, 0..100. Используется для сортировки выдачи
  /// и для метки качества в списке. null — если источник не оценивал.
  final int? qualityScore;

  /// Короткая метка качества для UI, например `HD`, `SD`, `LO`.
  final String? qualityLabel;

  /// Дополнительные данные источника (на случай если нужно вернуть в API).
  final Map<String, dynamic> extra;

  const Track({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.artist,
    this.duration,
    this.artworkUrl,
    this.qualityScore,
    this.qualityLabel,
    this.extra = const {},
  });


  /// Глобальный ID для использования в БД / очереди.
  String get globalId => '$sourceId:$id';

  Track copyWith({
    String? title,
    String? artist,
    Duration? duration,
    String? artworkUrl,
    int? qualityScore,
    String? qualityLabel,
  }) {
    return Track(
      id: id,
      sourceId: sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      qualityScore: qualityScore ?? this.qualityScore,
      qualityLabel: qualityLabel ?? this.qualityLabel,
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
        'quality_score': qualityScore,
        'quality_label': qualityLabel,
        'extra': extra,
      };

  /// Null-safe парсинг карты в [Track].
  ///
  /// SESSION-01: раньше `m['id'] as String` падал с
  /// `type 'Null' is not a subtype of type 'String'` на записях, сохранённых
  /// мобильным писателем с ключами `track_id`/`extra_json`. Теперь:
  /// - `id` читается с fallback на legacy-ключ `track_id` (формат мобильного
  ///   писателя до фикса); пустой `id` — невалидная запись, вызывающий код
  ///   её пропускает (per-entry skip в `PlaybackDao.loadPlaybackSession`);
  /// - отображаемые поля (`title`/`artist`) дефолтируются в '';
  /// - `extra` принимает и Map, и legacy JSON-строку `extra_json`;
  /// - числовые поля толерантны к num (JSON даёт int/double).
  factory Track.fromMap(Map<String, dynamic> m) => Track(
        id: _stringOrNull(m['id']) ?? _stringOrNull(m['track_id']) ?? '',
        sourceId: _stringOrNull(m['source_id']) ?? _stringOrNull(m['sourceId']) ?? '',
        title: _stringOrNull(m['title']) ?? '',
        artist: _stringOrNull(m['artist']) ?? '',
        duration: m['duration_ms'] != null
            ? Duration(milliseconds: (m['duration_ms'] as num).toInt())
            : null,
        artworkUrl: _stringOrNull(m['artwork_url']) ?? _stringOrNull(m['artworkUrl']),
        qualityScore: _intOrNull(m['quality_score']) ?? _intOrNull(m['qualityScore']),
        qualityLabel: _stringOrNull(m['quality_label']) ??
            _stringOrNull(m['qualityLabel']),
        extra: _extraFromMap(m['extra']) ??
            _extraFromJsonString(m['extra_json']) ??
            const {},
      );

  static String? _stringOrNull(dynamic v) => v is String ? v : null;

  static int? _intOrNull(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  /// `extra` в новом формате — Map (как пишет `toMap()`).
  static Map<String, dynamic>? _extraFromMap(dynamic v) {
    if (v is Map) return v.cast<String, dynamic>();
    return null;
  }

  /// `extra` в legacy-формате мобильного писателя — JSON-строка.
  static Map<String, dynamic>? _extraFromJsonString(dynamic v) {
    if (v is String && v.isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Track && other.globalId == globalId;

  @override
  int get hashCode => globalId.hashCode;
}
