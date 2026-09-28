import 'package:shared_preferences/shared_preferences.dart';

import '../core/youtube_cache.dart';
import 'muzmo_source.dart';
import 'soulseek_source.dart';
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
  ///
  /// Фаза 3 (DI): кэш аудио внедряется в источники через [cache].
  /// Если параметр не передан, источники сами используют
  /// [YoutubeCache.instance] (обратная совместимость).
  void registerDefaults({YoutubeCache? cache}) {
    // YouTube временно отключён для поиска: библиотека
    // youtube_explode_dart сломана (YouTube требует PoToken).
    // Источник остаётся зарегистрированным, чтобы плейлисты с
    // youtube-треками не крашились при попытке resolve.
    register(YoutubeSource(cache: cache));
    _disabledForSearch.add('youtube');

    register(MuzmoSource(cache: cache));
    register(SoundCloudSource(cache: cache));

    // Soulseek — регистрируем ВСЕГДА (обратная совместимость: треки из
    // плейлистов не крашатся при resolve). В searchable попадает только
    // если feature flag включён (см. [_soulseekEnabled]).
    register(SoulseekSource());
    if (!_soulseekEnabled) {
      _disabledForSearch.add('soulseek');
    }
  }

  // ───────────────────────────────────────────────────────────────────
  //  Soulseek feature flag
  // ───────────────────────────────────────────────────────────────────

  /// SharedPreferences-ключ для feature flag Soulseek.
  static const String _soulseekPrefKey = 'soulseek_enabled';

  /// Текущее состояние feature flag. По умолчанию выключен.
  ///
  /// Загружается из SharedPreferences через [loadSoulseekEnabled] при
  /// старте приложения (до вызова [registerDefaults]).
  static bool _soulseekEnabled = false;

  /// Возвращает текущее состояние feature flag Soulseek.
  static bool get isSoulseekEnabled => _soulseekEnabled;

  /// Загружает feature flag из SharedPreferences. Должна вызываться
  /// ДО [registerDefaults] (например, в main.dart перед инициализацией
  /// реестра источников).
  static Future<void> loadSoulseekEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _soulseekEnabled = prefs.getBool(_soulseekPrefKey) ?? false;
    } catch (_) {
      _soulseekEnabled = false;
    }
  }

  /// Включает или выключает Soulseek для поиска.
  ///
  /// Сохраняет значение в SharedPreferences и обновляет [_disabledForSearch]
  /// в реестре. Может вызываться в рантайме (UI Фазы 4: переключатель).
  static Future<void> setSoulseekEnabled(bool enabled) async {
    _soulseekEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_soulseekPrefKey, enabled);
    } catch (_) {}
    if (enabled) {
      instance._disabledForSearch.remove('soulseek');
    } else {
      instance._disabledForSearch.add('soulseek');
    }
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
    _disabledForSearch.clear();
  }
}
