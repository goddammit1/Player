import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/playlist.dart';
import '../../models/track.dart';
import '../artwork_helper.dart';
import '../database/app_database.dart';
import '../playlist_artwork_enricher.dart';
import '../backup/playlist_backup.dart';

/// Persistence + state-store для пользовательских плейлистов.
///
/// Хранилище — SQLite через [AppDatabase]. Публикует `Stream<List<Playlist>>`
/// (через `_controller.stream`) — UI подписывается на него через
/// Riverpod-провайдер. Запись на диск дебаунсится 300 мс.
///
/// Фоновое обогащение обложек вынесено в [PlaylistArtworkEnricher].
class PlaylistRepository {
  PlaylistRepository._();
  static final PlaylistRepository instance = PlaylistRepository._();

  static const _uuid = Uuid();
  static const Duration _persistDebounce = Duration(milliseconds: 300);

  /// Обогащение обложек, сконфигурированное на этот репозиторий.
  final PlaylistArtworkEnricher _enricher = PlaylistArtworkEnricher.instance;

  final StreamController<List<Playlist>> _controller =
      StreamController<List<Playlist>>.broadcast();
  List<Playlist> _list = [];
  Future<void>? _initFuture;
  Timer? _persistTimer;

  /// Связывает enricher с состоянием этого репозитория через колбэки.
  /// Идемпотентно; вызывается перед каждым вовлечением enricher.
  void _wireEnricher() {
    _enricher.readPlaylists = () => _list;
    _enricher.applyPlaylists = (next) {
      _list = next;
      _notifyAndSchedulePersist();
    };
  }

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
        '[PlaylistRepository] Failed to load playlists, keeping previous state if any: $e\n$st',
      );
      // Если список был пуст (первый запуск) — остаёмся с пустым списком.
      // Если были данные (reload после ошибки) — сохраняем их в памяти.
    }
    _controller.add(List.unmodifiable(_list));

    // Лениво дозагружаем/обновляем обложки для треков.
    // Запускаем в фоне, не блокируя UI.
    _wireEnricher();
    unawaited(_enricher.refreshArtworkCandidates());
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
        '[PlaylistRepository] Failed to persist playlists to DB: $e\n$st',
      );
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

  /// Reorder для drag&drop списка плейлистов.
  ///
  /// Семантика индексов — как у [ReorderableListView.onReorder]:
  /// [newIndex] указывает позицию ПОСЛЕ удаления элемента, т.е. при
  /// переносе вниз UI передаёт newIndex = target + 1.
  void reorderPlaylists(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _list.length) return;
    var ni = newIndex;
    if (ni > oldIndex) ni--;
    if (ni < 0) ni = 0;
    if (ni > _list.length - 1) ni = _list.length - 1;
    if (ni == oldIndex) return;
    final next = List<Playlist>.of(_list);
    final item = next.removeAt(oldIndex);
    next.insert(ni, item);
    _list = next;
    _notifyAndSchedulePersist();
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
      // Верхний кламп — length-1: после removeAt список короче на 1, и
      // insert(length) был бы RangeError (кламп к length — пре-существующий
      // баг, вскрытый тестами: reorderTracks(0, 999) падал).
      if (ni > p.tracks.length - 1) ni = p.tracks.length - 1;
      if (ni == oldIndex) return p;
      final t = List<Track>.of(p.tracks);
      final item = t.removeAt(oldIndex);
      t.insert(ni, item);
      changed = true;
      return p.copyWith(tracks: t);
    }).toList();
    if (changed) _notifyAndSchedulePersist();
  }

  /// Ищет плейлист по id.
  Playlist? findById(String id) {
    for (final p in _list) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Алиас для [findById] — обратная совместимость с устаревшим именем.
  Playlist? find(String id) => findById(id);

  /// Импортирует плейлисты из файла: для каждого импортируемого плейлиста
  /// всегда создаётся НОВЫЙ экземпляр с новым `id`, без проверки на
  /// дубликаты. Даже если плейлист идентичен по имени и/или содержимому
  /// уже существующему, он всё равно добавляется как новый — никакого
  /// выбора и пропуска конфликтов не происходит.
  ///
  /// Импортированные плейлисты вставляются в начало списка в порядке их
  /// следования в файле (первый из файла оказывается выше остальных
  /// импортированных). Ручной порядок существующих плейлистов сохраняется —
  /// никакой пересортировки по дате не выполняется.
  ///
  /// Возвращает статистику для UI.
  Future<ImportResult> importPlaylists(List<Playlist> incoming) async {
    await ensureLoaded();
    var added = 0;

    var working = List<Playlist>.of(_list);

    for (final src in incoming) {
      final clone = Playlist(
        id: _uuid.v4(),
        name: src.name,
        tracks: src.tracks,
        coverCustomUrl: src.coverCustomUrl,
        createdAt: DateTime.now(),
      );
      working = [clone, ...working];
      added++;
    }

    if (added > 0) {
      _list = working;
      _notifyAndSchedulePersist();
    }

    return ImportResult(added: added, replaced: 0, skipped: 0);
  }

  /// Принудительный flush на диск (например, перед закрытием app).
  Future<void> flush() async {
    _persistTimer?.cancel();
    await _persistNow();
  }

  /// Перечитывает данные из БД (нужный после импорта полного бэкапа).
  Future<void> reload() async {
    _initFuture = null;
    await _load();
  }

  // ===== Фоновое обогащение обложек (делегируется [PlaylistArtworkEnricher]) =====

  /// Обновляет [artworkUrl] у трека с указанным [globalId] во всех плейлистах,
  /// где он встречается.
  Future<void> updateTrackArtwork(String globalId, String artworkUrl) {
    _wireEnricher();
    return _enricher.updateTrackArtwork(globalId, artworkUrl);
  }

  /// Сбрасывает провайдерские/мёртвые кастомные обложки и перезапускает
  /// фоновую дозагрузку.
  void resetAllTrackArtworks() {
    _wireEnricher();
    _enricher.resetAllTrackArtworks();
  }

  /// Сбрасывает внутреннее состояние (для тестов и аварийного восстановления).
  @visibleForTesting
  Future<void> resetForTesting() async {
    // Отменяем отложенную запись и батч обложек, чтобы таймеры не сработали
    // уже после завершения теста.
    _persistTimer?.cancel();
    _wireEnricher();
    _enricher.resetForTesting();
    _initFuture = null;
    _list = [];
    // ignore: invalid_use_of_visible_for_testing_member
    await AppDatabase.instance.clearPlaylists();
    _controller.add(List.unmodifiable(_list));
  }

  /// Тестовый хук: дожидается завершения ВСЕЙ волны обогащения обложек.
  @visibleForTesting
  Future<void> flushEnrichmentForTesting() {
    _wireEnricher();
    return _enricher.flushEnrichmentForTesting();
  }
}
