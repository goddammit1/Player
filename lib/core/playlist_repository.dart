import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'playlist_backup.dart';

/// Persistence + state-store для пользовательских плейлистов.
///
/// Хранилище — `SharedPreferences`, единый ключ `playlists_v1` с
/// JSON-массивом сериализованных плейлистов. На реальных данных
/// (≤ 50 плейлистов × ≤ 500 треков) это работает мгновенно и не
/// требует SQLite. Когда понадобятся серьёзные запросы — перенесём в
/// `sqflite`.
///
/// Публикует `Stream<List<Playlist>>` (через `_controller.stream`) —
/// UI подписывается на него через Riverpod-провайдер. Запись на диск
/// дебаунсится 300 мс: серия быстрых правок (add → add → rename)
/// сольётся в одну запись.
class PlaylistRepository {
  PlaylistRepository._();
  static final PlaylistRepository instance = PlaylistRepository._();

  static const String _key = 'playlists_v1';
  static const _uuid = Uuid();
  static const Duration _persistDebounce = Duration(milliseconds: 300);

  final StreamController<List<Playlist>> _controller =
      StreamController<List<Playlist>>.broadcast();
  List<Playlist> _list = [];
  SharedPreferences? _prefs;
  Future<void>? _initFuture;
  Timer? _persistTimer;

  /// Поток плейлистов в текущем порядке (новые сверху).
  Stream<List<Playlist>> get stream => _controller.stream;

  /// Текущий снимок, в т.ч. до подписки на стрим. Безопасно читать
  /// после `ensureLoaded()`.
  List<Playlist> get current => List.unmodifiable(_list);

  /// Гарантирует, что данные подняты с диска и стрим имеет хотя бы
  /// одно значение для новых подписчиков.
  Future<void> ensureLoaded() {
    _initFuture ??= _load();
    return _initFuture!;
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw == null || raw.isEmpty) {
      _list = [];
      _controller.add(_list);
      return;
    }
    try {
      final arr = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _list = arr.map(Playlist.fromJson).toList();
      // Сортируем «новые сверху» — это удобный дефолт для UI.
      _list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      // Битый JSON в проде лучше игнорировать, чем падать.
      _list = [];
    }
    _controller.add(List.unmodifiable(_list));
  }

  void _notifyAndSchedulePersist() {
    _controller.add(List.unmodifiable(_list));
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persistNow);
  }

  Future<void> _persistNow() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = jsonEncode(_list.map((p) => p.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  // ===== Mutations =====

  Playlist create(String name) {
    final p = Playlist(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'New playlist' : name.trim(),
      tracks: const [],
      createdAt: DateTime.now(),
    );
    _list = [p, ..._list];
    _notifyAndSchedulePersist();
    return p;
  }

  void delete(String id) {
    final n = _list.length;
    _list = _list.where((p) => p.id != id).toList();
    if (_list.length != n) _notifyAndSchedulePersist();
  }

  void rename(String id, String name) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != id) return p;
      changed = true;
      return p.copyWith(name: name.trim().isEmpty ? p.name : name.trim());
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Добавляет трек в конец плейлиста. Без дедупликации.
  void addTrack(String id, Track track) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != id) return p;
      changed = true;
      return p.copyWith(tracks: [...p.tracks, track]);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Удаляет первое вхождение трека по `globalId`.
  void removeTrack(String playlistId, String trackGlobalId) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != playlistId) return p;
      final newTracks = List<Track>.of(p.tracks);
      final idx = newTracks.indexWhere((t) => t.globalId == trackGlobalId);
      if (idx == -1) return p;
      newTracks.removeAt(idx);
      changed = true;
      return p.copyWith(tracks: newTracks);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Reorder для drag&drop в UI.
  void reorderTracks(String playlistId, int oldIndex, int newIndex) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != playlistId) return p;
      if (oldIndex < 0 || oldIndex >= p.tracks.length) return p;
      var ni = newIndex;
      if (ni > oldIndex) ni--;
      if (ni < 0) ni = 0;
      if (ni > p.tracks.length) ni = p.tracks.length;
      if (ni == oldIndex) return p;
      final t = List<Track>.of(p.tracks);
      final item = t.removeAt(oldIndex);
      t.insert(ni, item);
      changed = true;
      return p.copyWith(tracks: t);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  Playlist? find(String id) {
    for (final p in _list) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Импортирует плейлисты из бэкапа с выбранной стратегией разрешения
  /// коллизий по `id`. Возвращает статистику для UI.
  ///
  /// - [ImportStrategy.replace] — существующий плейлист с тем же `id`
  ///   полностью заменяется импортируемым.
  /// - [ImportStrategy.keepBoth] — импортируемому выдаётся новый `id`,
  ///   так что оба плейлиста остаются (удобно, когда хочешь смержить
  ///   две библиотеки).
  /// - [ImportStrategy.skip] — плейлист с конфликтующим `id`
  ///   пропускается, существующий остаётся нетронутым.
  ImportResult importPlaylists(
    List<Playlist> incoming, {
    required ImportStrategy strategy,
  }) {
    var added = 0;
    var replaced = 0;
    var skipped = 0;

    final byId = {for (final p in _list) p.id: p};
    var working = List<Playlist>.of(_list);

    for (final src in incoming) {
      final exists = byId.containsKey(src.id);
      if (!exists) {
        working = [src, ...working];
        byId[src.id] = src;
        added++;
        continue;
      }
      switch (strategy) {
        case ImportStrategy.replace:
          working = working.map((p) => p.id == src.id ? src : p).toList();
          byId[src.id] = src;
          replaced++;
        case ImportStrategy.keepBoth:
          final clone = Playlist(
            id: _uuid.v4(),
            name: src.name,
            tracks: src.tracks,
            coverCustomUrl: src.coverCustomUrl,
            createdAt: DateTime.now(),
          );
          working = [clone, ...working];
          byId[clone.id] = clone;
          added++;
        case ImportStrategy.skip:
          skipped++;
      }
    }

    if (added > 0 || replaced > 0) {
      working.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _list = working;
      _notifyAndSchedulePersist();
    }

    return ImportResult(added: added, replaced: replaced, skipped: skipped);
  }

  /// Принудительный flush на диск (например, перед закрытием app).
  Future<void> flush() async {
    _persistTimer?.cancel();
    await _persistNow();
  }
}
