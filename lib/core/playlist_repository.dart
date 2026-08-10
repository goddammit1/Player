import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../sources/artwork_provider.dart';
import 'app_database.dart';
import 'artwork_helper.dart';
import '../models/track.dart';
import 'playlist_backup.dart';

/// Persistence + state-store для пользовательских плейлистов.
///
/// Хранилище — SQLite через [AppDatabase]. Публикует `Stream<List<Playlist>>`
/// (через `_controller.stream`) — UI подписывается на него через
/// Riverpod-провайдер. Запись на диск дебаунсится 300 мс.
class PlaylistRepository {
  PlaylistRepository._();
  static final PlaylistRepository instance = PlaylistRepository._();

  static const _uuid = Uuid();
  static const Duration _persistDebounce = Duration(milliseconds: 300);

  final StreamController<List<Playlist>> _controller =
      StreamController<List<Playlist>>.broadcast();
  List<Playlist> _list = [];
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
    try {
      _list = await AppDatabase.instance.loadPlaylists();
    } catch (e, st) {
      // Логируем ошибку, но не сбрасываем текущий список на пустой —
      // иначе при любой ошибке БД все данные теряются необратимо.
      debugPrint(
          '[PlaylistRepository] Failed to load playlists, keeping previous state if any: $e\n$st');
      // Если список был пуст (первый запуск) — остаёмся с пустым списком.
      // Если были данные (reload после ошибки) — сохраняем их в памяти.
    }
    _controller.add(List.unmodifiable(_list));

    // Лениво дозагружаем обложки для треков без artworkUrl.
    // Запускаем в фоне, не блокируя UI.
    _enrichMissingArtworks();
  }

  void _enrichMissingArtworks() {
    // Собираем все треки без обложек со всех плейлистов.
    final Set<String> seen = {};
    for (final p in _list) {
      for (final t in p.tracks) {
        if (t.artworkUrl == null || t.artworkUrl!.isEmpty) {
          final key = t.globalId;
          if (seen.add(key)) {
            _fetchAndApplyArtworkForTrack(t);
          }
        }
      }
    }
  }

  void _fetchAndApplyArtworkForTrack(Track track) {
    // Отложенный импорт во избежание циклической зависимости.
    // ArtworkProvider лежит в sources/, он не зависит от playlist_repository.
    ArtworkProvider.instance.findArtwork(track.artist, track.title, preferredSize: 600).then((url) {
      if (url == null || url.isEmpty) return;
      updateTrackArtwork(track.globalId, url);
    }).catchError((_) {});
  }

  void _notifyAndSchedulePersist() {
    _controller.add(List.unmodifiable(_list));
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persistNow);
  }

  Future<void> _persistNow() async {
    try {
      await AppDatabase.instance.saveAllPlaylists(_list);
    } catch (e, st) {
      // Логируем ошибку записи, чтобы в логах было видно.
      // Данные в памяти остаются актуальными, но при следующем запуске
      // загрузятся с диска (устаревшие). Пользователь может потерять
      // последние изменения, но не все данные.
      debugPrint(
          '[PlaylistRepository] Failed to persist playlists to DB: $e\n$st');
    }
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
    // Удаляем файл кастомной обложки перед удалением плейлиста
    final playlist = find(id);
    if (playlist?.coverCustomUrl != null) {
      ArtworkHelper.removePlaylistCover(playlist!.coverCustomUrl!);
    }

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

  /// Устанавливает кастомную обложку плейлиста.
  void setCoverCustom(String id, String url) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != id) return p;
      changed = true;
      return p.copyWith(coverCustomUrl: url);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Алиас для [setCoverCustom] — обратная совместимость.
  void setCoverImage(String id, String path) => setCoverCustom(id, path);

  /// Алиас для [clearCoverCustom] — обратная совместимость.
  void removeCoverImage(String id) => clearCoverCustom(id);

  /// Сбрасывает кастомную обложку (удаляет).
  void clearCoverCustom(String id) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != id) return p;
      changed = true;
      return p.copyWith(coverCustomUrl: null);
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

  /// Добавляет трек сразу в несколько плейлистов одной транзакцией.
  /// Это снижает количество rebuild'ов UI с N до 1.
  void addTrackToMany(Iterable<String> ids, Track track) {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;

    var changed = false;
    _list = _list.map((p) {
      if (!idSet.contains(p.id)) return p;
      changed = true;
      return p.copyWith(tracks: [...p.tracks, track]);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Заменяет трек в плейлисте по `globalId` старого трека на новый.
  void replaceTrack(String playlistId, String oldGlobalId, Track newTrack) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != playlistId) return p;
      final newTracks = List<Track>.of(p.tracks);
      final idx = newTracks.indexWhere((t) => t.globalId == oldGlobalId);
      if (idx == -1) return p;
      newTracks[idx] = newTrack;
      changed = true;
      return p.copyWith(tracks: newTracks);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Удаляет трек по индексу в плейлисте.
  void removeTrackAt(String playlistId, int index) {
    var changed = false;
    _list = _list.map((p) {
      if (p.id != playlistId) return p;
      if (index < 0 || index >= p.tracks.length) return p;
      final newTracks = List<Track>.of(p.tracks);
      newTracks.removeAt(index);
      changed = true;
      return p.copyWith(tracks: newTracks);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Удаляет первое вхождение трека по `globalId`.
  ///
  /// Устаревший метод: при дубликатах трека удаляет первое вхождение.
  /// Используйте [removeTrackAt] для точного удаления.
  @Deprecated('Use removeTrackAt to delete by exact index')
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
  Future<ImportResult> importPlaylists(
    List<Playlist> incoming, {
    required ImportStrategy strategy,
  }) async {
    await ensureLoaded();
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

  /// Сбрасывает внутреннее состояние (для тестов и аварийного восстановления).
  @visibleForTesting
  Future<void> resetForTesting() async {
    // Отменяем отложенную запись, чтобы debounce-таймер не сработал
    // уже после завершения теста.
    _persistTimer?.cancel();
    _initFuture = null;
    _list = [];
    // ignore: invalid_use_of_visible_for_testing_member
    await AppDatabase.instance.clearPlaylists();
    _controller.add(List.unmodifiable(_list));
  }

  /// Обновляет [artworkUrl] у трека с указанным [globalId] во всех плейлистах,
  /// где он встречается. Вызывается после ленивой подгрузки обложки через
  /// [ArtworkProvider], чтобы обложка попала в БД и отображалась в плейлистах.
  void updateTrackArtwork(String globalId, String artworkUrl) {
    var changed = false;
    final newList = <Playlist>[];
    for (final p in _list) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        if (t.globalId == globalId && t.artworkUrl != artworkUrl) {
          playlistChanged = true;
          return t.copyWith(artworkUrl: artworkUrl);
        }
        return t;
      }).toList();
      if (playlistChanged) {
        changed = true;
        newList.add(p.copyWith(tracks: newTracks));
      } else {
        newList.add(p);
      }
    }
    if (changed) {
      _list = newList;
      _notifyAndSchedulePersist();
    }
  }

  /// Сбрасывает [artworkUrl] на null у всех треков во всех плейлистах.
  /// Нужно после очистки кэша обложек — треки перезапросят обложки
  /// через ArtworkProvider при следующем проигрывании.
  void resetAllTrackArtworks() {
    var anyChanged = false;
    _list = _list.map((p) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        if (t.artworkUrl != null) {
          playlistChanged = true;
          return t.copyWith(artworkUrl: null);
        }
        return t;
      }).toList();
      if (playlistChanged) {
        anyChanged = true;
        return p.copyWith(tracks: newTracks);
      }
      return p;
    }).toList();
    if (anyChanged) _notifyAndSchedulePersist();
  }

  /// Перечитывает данные из БД (нужно после импорта полного бэкапа).
  Future<void> reload() async {
    _initFuture = null;
    await _load();
  }
}
