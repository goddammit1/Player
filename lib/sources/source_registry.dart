import 'muzmo_source.dart';
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

  /// Зарегистрировать все известные источники.
  void registerDefaults() {
    register(YoutubeSource());
    register(MuzmoSource());
    // register(SoundCloudSource());
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

  Future<void> disposeAll() async {
    for (final s in _sources.values) {
      await s.dispose();
    }
    _sources.clear();
  }
}
