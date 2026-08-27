// lib/sources/conversion.dart
//
// Слой конверсии данных (Фаза 2, шаги 2.2–2.3 плана рефакторинга).
//
// Цель: убрать смешение слоёв, когда конверсия MediaItem→Track жила
// в UI-виджете (queue_sheet.dart). Все конверсии между моделями данных
// собраны здесь — на уровне данных, отдельно от presentation-слоя.

import 'package:audio_service/audio_service.dart' show MediaItem;

import '../models/track.dart';

/// Конвертирует [MediaItem] (плеерная модель audio_service) в [Track] —
/// унифицированную модель приложения.
///
/// Выделено из `lib/ui/widgets/queue_sheet.dart`, чтобы UI не содержал
/// конверсии моделей данных (разделение слоёв данных и presentation).
Track mediaItemToTrack(MediaItem item) {
  final extra = item.extras ?? {};
  final sourceId = (extra['sourceId'] as String?) ??
      (extra['source_id'] as String?) ??
      'local';
  return Track(
    // Чистый id трека в источнике. `item.id` у MediaItem — это полный
    // globalId (`sourceId:trackId`), поэтому предпочитаем extras['trackId'].
    // Иначе cacheId для очереди строился бы из лишнего префикса источника
    // (`muzmo_muzmo:<id>` вместо `muzmo_<id>`) и кэш бы не совпадал с тем,
    // что показывает большое меню трека.
    id: extra['trackId'] as String? ?? item.id,
    sourceId: sourceId,
    title: item.title,
    artist: item.artist ?? '',
    duration: item.duration,
    artworkUrl: item.artUri?.toString(),
    qualityScore: extra['quality_score'] as int?,
    qualityLabel: extra['quality_label'] as String?,
    extra: extra,
  );
}