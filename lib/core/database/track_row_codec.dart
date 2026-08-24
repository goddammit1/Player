import 'dart:convert';

import '../../models/track.dart';

/// Кодек строк БД: конвертация SQLite-строк в модели и обратно.
///
/// Выделено из монолита `AppDatabase`, чтобы переиспользовать общие
/// преобразования `Track` <-> Map между доменными DAO без дублирования.
abstract class TrackRowCodec {
  /// Конвертирует SQL-строку таблицы `*_tracks` в [Track].
  static Track fromRow(Map<String, dynamic> row) {
    Map<String, dynamic> extra = const {};
    if (row['extra_json'] != null &&
        (row['extra_json'] as String).isNotEmpty) {
      try {
        extra = (jsonDecode(row['extra_json'] as String) as Map)
            .cast<String, dynamic>();
      } catch (_) {}
    }
    return Track(
      id: row['track_id'] as String,
      sourceId: row['source_id'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String,
      duration: row['duration_ms'] != null
          ? Duration(milliseconds: (row['duration_ms'] as num).toInt())
          : null,
      artworkUrl: row['artwork_url'] as String?,
      qualityScore: row['quality_score'] as int?,
      qualityLabel: row['quality_label'] as String?,
      extra: extra,
    );
  }

  /// Рекурсивно обходит [extra] и заменяет все значения на JSON-совместимые
  /// примитивы (String/num/bool/null) либо их вложенные коллекции.
  static Map<String, dynamic> extraPrimitives(Map<String, dynamic> extra) {
    return extra.map((k, v) => MapEntry(k, _toPrimitive(v)));
  }

  static dynamic _toPrimitive(dynamic v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _toPrimitive(val)));
    }
    if (v is List) {
      return v.map((e) => _toPrimitive(e)).toList();
    }
    return v.toString();
  }
}