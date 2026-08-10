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

  /// Максимум одновременных фоновых запросов обложек. Каждый трек внутри
  /// [ArtworkProvider.findArtwork] даёт 2 параллельных HTTP-запроса
  /// (Genius + iTunes), поэтому даже 3 слота = 6 запросов в один момент.
  static const int _maxEnrichConcurrency = 3;

  /// Сколько треков без обложек обогащается за один `_load()`. Предохраняет
  /// от сетевого шторма на старте приложения при большой библиотеке.
  static const int _maxEnrichPerLoad = 50;

  /// Частота применения накопленного батча обложек: пачка найденных URL
  /// применяется одним эмитом в стрим и одной записью в БД.
  static const Duration _artworkFlushInterval = Duration(milliseconds: 150);

  final StreamController<List<Playlist>> _controller =
      StreamController<List<Playlist>>.broadcast();
  List<Playlist> _list = [];
  Future<void>? _initFuture;
  Timer? _persistTimer;

  // ---- Фоновое обогащение обложек ----
  final _Semaphore _enrichSemaphore = _Semaphore(_maxEnrichConcurrency);
  final Set<Future<void>> _enrichmentInFlight = {};
  final List<({String globalId, String url})> _pendingArtwork = [];
  Timer? _artworkFlushTimer;

  /// Инкрементируется при сбросе обложек / сбросе состояния. In-flight
  /// результаты с устаревшим значением не применяются — защита от гонки
  /// «очистили кэш обложек, а прилетевший URL вернул обложку обратно».
  int _artworkGeneration = 0;

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

    // Лениво дозагружаем обложки для треков без artworkUrl.
    // Запускаем в фоне, не блокируя UI.
    _enrichMissingArtworks();
  }

  /// Лениво дозагружает обложки для треков без artworkUrl.
  ///
  /// Фоновое обогащение ограничено, чтобы старт приложения не превращался
  /// в сетевой шторм:
  /// - за один `_load()` обрабатывается не более [_maxEnrichPerLoad] треков;
  /// - одновременно летит не более [_maxEnrichConcurrency] запросов;
  /// - треки с пустыми artist/title пропускаются — по ним нет смысла искать.
  ///
  /// Найденные URL не применяются по одному: они копятся в [_pendingArtwork]
  /// и применяются раз в [_artworkFlushInterval] одной пачкой — один emit
  /// в стрим и одна запись в БД вместо N (N пересборок UI + N saveAllPlaylists).
  void _enrichMissingArtworks() {
    final candidates = <Track>[];
    final seen = <String>{};
    for (final p in _list) {
      for (final t in p.tracks) {
        if (t.artworkUrl == null || t.artworkUrl!.isEmpty) {
          if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
          if (seen.add(t.globalId)) candidates.add(t);
        }
      }
    }
    for (final track in candidates.take(_maxEnrichPerLoad)) {
      final future = _fetchAndApplyArtworkForTrack(track);
      _enrichmentInFlight.add(future);
      unawaited(future.whenComplete(() => _enrichmentInFlight.remove(future)));
    }
  }

  Future<void> _fetchAndApplyArtworkForTrack(Track track) async {
    // Семафор ограничивает одновременные запросы: в плейлистах могут быть
    // сотни треков без обложек, а каждый findArtwork даёт 2 параллельных
    // HTTP-запроса (Genius + iTunes). Без лимита старт приложения = десятки
    // одновременных запросов → rate-limits и тормоза сети/UI.
    await _enrichSemaphore.acquire();
    final generation = _artworkGeneration;
    try {
      final url = await ArtworkProvider.instance.findArtwork(
        track.artist,
        track.title,
        preferredSize: 600,
      );
      // Пока запрос летел, обложки могли сбросить (очистка кэша) или
      // плейлисты перезагрузить — устаревший результат не применяем,
      // иначе «сброс» откатился бы прилетевшим URL.
      if (generation != _artworkGeneration) return;
      if (url == null || url.isEmpty) return;
      _queueArtworkUpdate(track.globalId, url);
    } catch (_) {
      // Индивидуальные ошибки провайдера не роняют весь enrichment.
    } finally {
      _enrichSemaphore.release();
    }
  }

  /// Копит найденные обложки и применяет их одной пачкой через
  /// [_artworkFlushInterval] — один emit в стрим и один persist на пачку.
  void _queueArtworkUpdate(String globalId, String url) {
    _pendingArtwork.add((globalId: globalId, url: url));
    _artworkFlushTimer ??= Timer(_artworkFlushInterval, _flushArtworkBatch);
  }

  void _flushArtworkBatch() {
    _artworkFlushTimer = null;
    if (_pendingArtwork.isEmpty) return;
    final batch = List.of(_pendingArtwork);
    _pendingArtwork.clear();
    _applyArtworkUpdates(batch);
  }

  /// Применяет пачку обновлений обложек одним проходом: один emit в стрим
  /// и один дебаунс-персист. При дублях globalId внутри пачки побеждает
  /// последний URL.
  void _applyArtworkUpdates(Iterable<({String globalId, String url})> updates) {
    final byGlobalId = <String, String>{};
    for (final u in updates) {
      byGlobalId[u.globalId] = u.url;
    }

    var changed = false;
    final newList = <Playlist>[];
    for (final p in _list) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        final url = byGlobalId[t.globalId];
        if (url != null && t.artworkUrl != url) {
          playlistChanged = true;
          return t.copyWith(artworkUrl: url);
        }
        return t;
      }).toList();
      if (playlistChanged) changed = true;
      newList.add(playlistChanged ? p.copyWith(tracks: newTracks) : p);
    }
    if (changed) {
      _list = newList;
      _notifyAndSchedulePersist();
    }
  }

  /// Копия трека без обложки. Нужна в [resetAllTrackArtworks]: обычный
  /// `copyWith(artworkUrl: null)` не сбрасывает URL — copyWith игнорирует null.
  static Track _withoutArtwork(Track t) => Track(
    id: t.id,
    sourceId: t.sourceId,
    title: t.title,
    artist: t.artist,
    duration: t.duration,
    artworkUrl: null,
    qualityScore: t.qualityScore,
    qualityLabel: t.qualityLabel,
    extra: t.extra,
  );

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
    // Отменяем отложенную запись и батч обложек, чтобы таймеры не сработали
    // уже после завершения теста.
    _persistTimer?.cancel();
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();
    _artworkGeneration++;
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
    _applyArtworkUpdates([(globalId: globalId, url: artworkUrl)]);
  }

  /// Сбрасывает [artworkUrl] на null только у тех треков, чья обложка
  /// была найдена самим ArtworkProvider (Genius/iTunes), и сразу
  /// запускает фоновую дозагрузку обложек через [_enrichMissingArtworks],
  /// чтобы плейлисты снова заполнились без ручного воспроизведения
  /// каждого трека.
  ///
  /// Обложки, которые дал сам источник (SoundCloud `sndcdn.com`,
  /// YouTube `i.ytimg.com`, локальные файлы `/...` и `file://...`),
  /// НЕ сбрасываются: они стабильны, и после очистки дискового кэша
  /// CachedNetworkImage скачает их заново по тому же URL. Также отменяет
  /// накопленный батч и инвалидирует in-flight запросы, чтобы URL,
  /// прилетевшие ДО сброса, не вернули обложки обратно; запросы, запущенные
  /// самим сбросом (уже после инкремента [_artworkGeneration]), применяются
  /// как обычно.
  void resetAllTrackArtworks() {
    _artworkGeneration++;
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _pendingArtwork.clear();

    var anyChanged = false;
    _list = _list.map((p) {
      var playlistChanged = false;
      final newTracks = p.tracks.map((t) {
        final url = t.artworkUrl;
        if (url != null && ArtworkProvider.isProviderArtworkUrl(url)) {
          playlistChanged = true;
          return _withoutArtwork(t);
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

    // Перезапускаем фоновую дозагрузку: кандидаты — треки, у которых теперь
    // нет URL. Старые in-flight запросы уже инвалидированы инкрементом
    // _artworkGeneration выше, поэтому их результаты не применятся.
    _enrichMissingArtworks();
  }

  /// Перечитывает данные из БД (нужно после импорта полного бэкапа).
  Future<void> reload() async {
    _initFuture = null;
    await _load();
  }

  /// Тестовый хук: дожидается завершения всех in-flight запросов обложек
  /// и применяет накопленный батч, не ожидая [_artworkFlushInterval].
  @visibleForTesting
  Future<void> flushEnrichmentForTesting() async {
    while (_enrichmentInFlight.isNotEmpty) {
      await Future.wait(List.of(_enrichmentInFlight));
    }
    _artworkFlushTimer?.cancel();
    _artworkFlushTimer = null;
    _flushArtworkBatch();
  }
}

/// Простой семафор с фиксированным числом слотов — ограничивает число
/// одновременных фоновых запросов обложек (см. [_maxEnrichConcurrency]).
class _Semaphore {
  _Semaphore(this._slots);

  final int _slots;
  int _used = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_used < _slots) {
      _used++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _used--;
    }
  }
}
