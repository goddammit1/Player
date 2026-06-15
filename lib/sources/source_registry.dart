import 'muzmo_source.dart';
import 'soundcloud_source.dart';
import 'track_source.dart';
import 'youtube_source.dart';

/// Реестр всех доступных источников.
///
/// Регистрация происходит один раз при старте приложения.
/// В будущем можно добавлять источники: `register(SoundCloudSource())` и т.п.
class SourceRegistry {
  SourceRegistry._();
  static final SourceRegistry instance = SourceRegistry._();

  final Map<String, TrackSource> _sources = {};

  /// Источники, отключённые для поиска (но зарегистрированные для
  /// обратной совместимости — треки из плейлистов всё ещё ссылаются
  /// на них по sourceId).
  final Set<String> _disabledForSearch = {};

  /// Зарегистрировать все известные источники.
  void registerDefaults() {
    // YouTube временно отключён для поиска: библиотека
    // youtube_explode_dart сломана (YouTube требует PoToken).
    // Источник остаётся зарегистрированным, чтобы плейлисты с
    // youtube-треками не крашились при попытке resolve.
    register(YoutubeSource());
    _disabledForSearch.add('youtube');

    register(MuzmoSource());
    register(SoundCloudSource());
  }

  void register(TrackSource source) {
    _sources[source.id] = source;
  }

  TrackSource? get(String id) => _sources[id];

  TrackSource require(String id) {
    final s = _sources[id];
    if (s == null) {
      throw StateError('Source "$id" is not registered');
    }
    return s;
  }

  List<TrackSource> get all => _sources.values.toList(growable: false);

  /// Источники, доступные для поиска (исключая временно отключённые).
  List<TrackSource> get searchable => _sources.values
      .where((s) => !_disabledForSearch.contains(s.id))
      .toList(growable: false);

  /// Проверяет, отключён ли источник для поиска/воспроизведения.
  bool isDisabled(String sourceId) => _disabledForSearch.contains(sourceId);

  Future<void> disposeAll() async {
    for (final s in _sources.values) {
      await s.dispose();
    }
    _sources.clear();
  }
}
