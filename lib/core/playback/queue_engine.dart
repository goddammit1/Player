// lib/core/playback/queue_engine.dart
//
// Общее ядро плеера для мобилки и десктопа: очередь, `_playIndex` с
// поколениями загрузок, retry с инвалидацией кэша, пропуск после ошибки,
// prefetch следующего трека, порог записи в историю, sleep timer, boost,
// сохранение/восстановление сессии и подтягивание обложек.
//
// Само воспроизведение — за [PlaybackBackend] (мобилка: just_audio,
// десктоп: media_kit), всё остальное приложение — за [QueueEnvironment].

import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:rxdart/rxdart.dart';

import '../../models/track.dart';
import '../player_conversions.dart';
import '../player_service_interface.dart';
import 'playback_backend.dart';
import 'queue_environment.dart';

class QueueEngine implements PlayerServiceInterface {
  QueueEngine({
    required PlaybackBackend backend,
    QueueEnvironment environment = const DefaultQueueEnvironment(),
    bool persistVolume = false,
    String logTag = 'Player',
  })  : _backend = backend,
        _env = environment,
        _persistVolume = persistVolume,
        _logTag = logTag {
    _subs.add(_backend.stateChanges.listen((_) => _emitPlaybackState()));
    _subs.add(_backend.completed.listen((_) {
      if (_isLoading) {
        _log('completed ignored (already loading gen=$_loadGeneration)');
        return;
      }
      _onTrackFinished();
    }));
    _subs.add(_backend.positionStream.listen(_onPosition));
    ready = _init();
  }

  final PlaybackBackend _backend;
  final QueueEnvironment _env;
  final bool _persistVolume;
  final String _logTag;
  final List<StreamSubscription<Object?>> _subs = [];

  /// Завершается после восстановления boost / громкости / сессии.
  late final Future<void> ready;

  // print -> adb logcat (tag: flutter)
  void _log(String msg) => debugPrint('[$_logTag] $msg');

  static const String _boostDbKey = 'boost_db_v1';
  static const String _volumeKey = 'volume_v1';

  // ===== Состояние =====

  final List<Track> _queue = [];
  int _currentIndex = -1;
  int _loadGeneration = 0;
  bool _isLoading = false;

  final _currentIndexSubject = BehaviorSubject<int>.seeded(-1);
  final _queueSubject = BehaviorSubject<List<Track>>.seeded(const []);
  final _mediaItemSubject = BehaviorSubject<MediaItem?>.seeded(null);
  final _playbackStateSubject =
      BehaviorSubject<PlaybackState>.seeded(PlaybackState());
  final _loopMode = BehaviorSubject<LoopMode>.seeded(LoopMode.off);
  final _boostDb = BehaviorSubject<double>.seeded(0.0);
  final _volume = BehaviorSubject<double>.seeded(1.0);
  final _sleepTimerMode =
      BehaviorSubject<SleepTimerMode>.seeded(SleepTimerMode.off);
  final _sleepTimerEndTime = BehaviorSubject<DateTime?>.seeded(null);

  @override
  bool get isLoading => _isLoading;
  @override
  int get currentIndex => _currentIndex;
  @override
  Stream<int> get currentIndexStream => _currentIndexSubject.stream;

  @override
  List<Track> get trackQueue => List.unmodifiable(_queue);
  @override
  Stream<List<Track>> get trackQueueStream => _queueSubject.stream;

  @override
  Stream<MediaItem?> get mediaItem => _mediaItemSubject.stream;
  @override
  MediaItem? get mediaItemValue => _mediaItemSubject.value;
  @override
  Stream<PlaybackState> get playbackState => _playbackStateSubject.stream;

  @override
  LoopMode get loopMode => _loopMode.value;
  @override
  Stream<LoopMode> get loopModeStream => _loopMode.stream;

  @override
  double get boostDb => _boostDb.value;
  @override
  Stream<double> get boostDbStream => _boostDb.stream;

  @override
  double get volume => _volume.value;
  @override
  Stream<double> get volumeStream => _volume.stream;

  @override
  SleepTimerMode get sleepTimerMode => _sleepTimerMode.value;
  @override
  Stream<SleepTimerMode> get sleepTimerModeStream => _sleepTimerMode.stream;
  @override
  DateTime? get sleepTimerEndTime => _sleepTimerEndTime.value;
  @override
  Stream<DateTime?> get sleepTimerEndTimeStream => _sleepTimerEndTime.stream;

  @override
  Stream<Duration> get positionStream => _backend.positionStream;
  @override
  Stream<Duration?> get durationStream => _backend.durationStream;
  @override
  Stream<bool> get playingStream => _backend.playingStream;

  Future<void> _init() async {
    await _initBoost();
    if (_persistVolume) await _initVolume();
    await _restoreSession();
  }

  void _setCurrentIndex(int index) {
    _currentIndex = index;
    if (!_currentIndexSubject.isClosed) _currentIndexSubject.add(index);
  }

  /// Публикует снимок очереди после каждой мутации.
  void _notifyQueue() {
    if (_queueSubject.isClosed) return;
    _queueSubject.add(List.unmodifiable(_queue));
  }

  void _emitMediaItem(MediaItem? item) {
    if (!_mediaItemSubject.isClosed) _mediaItemSubject.add(item);
  }

  void _emitPlaybackState() {
    if (_playbackStateSubject.isClosed) return;
    final playing = _backend.playing;
    _playbackStateSubject.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: _backend.processingState,
      playing: playing,
      updatePosition: _backend.position,
      bufferedPosition: _backend.bufferedPosition,
      speed: _backend.speed,
      queueIndex: _currentIndex >= 0 ? _currentIndex : null,
    ));
  }

  // ===== История прослушивания =====
  // Трек попадает в историю только после того, как реально отыграл
  // [_historyThreshold] и продолжает играть: ошибки и мгновенные скипы
  // не дают «фантомных» записей.

  Track? _pendingHistoryTrack;
  static const Duration _historyThreshold = Duration(seconds: 1);

  void _onPosition(Duration pos) {
    final pending = _pendingHistoryTrack;
    if (pending == null) return;
    if (!_backend.playing) return;
    if (pos < _historyThreshold) return;
    _pendingHistoryTrack = null;
    // Актуальная версия трека из очереди — к этому моменту
    // _fetchAndApplyArtwork мог уже обновить artworkUrl.
    final current = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : pending;
    unawaited(_env.addToHistory(current).catchError((Object e) {
      _log('history add failed: $e');
    }));
  }

  // ===== Sleep timer =====

  Timer? _sleepTimer;

  @override
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.time);
    _sleepTimerEndTime.add(DateTime.now().add(duration));
    _sleepTimer = Timer(duration, () {
      _log('Sleep timer: time expired, waiting for current track to finish');
      // Время вышло — доигрываем текущий трек и останавливаемся.
      _sleepTimerMode.add(SleepTimerMode.endOfTrack);
      _sleepTimerEndTime.add(null);
    });
  }

  @override
  Future<void> setStopAtEndOfSong() async {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.endOfTrack);
    _sleepTimerEndTime.add(null);
  }

  @override
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    if (!_sleepTimerMode.isClosed) _sleepTimerMode.add(SleepTimerMode.off);
    if (!_sleepTimerEndTime.isClosed) _sleepTimerEndTime.add(null);
  }

  // ===== Авто-переход при завершении трека =====

  void _onTrackFinished() {
    if (sleepTimerMode == SleepTimerMode.endOfTrack) {
      _log('Sleep timer: end of track reached, stopping');
      cancelSleepTimer();
      return;
    }
    switch (_loopMode.value) {
      case LoopMode.one:
        _log('LoopMode.one → replay index=$_currentIndex');
        unawaited(_playIndex(_currentIndex));
      case LoopMode.all:
        final next = _currentIndex + 1;
        if (next < _queue.length) {
          unawaited(_playIndex(next));
        } else if (_queue.isNotEmpty) {
          _log('LoopMode.all → wrap to index=0');
          unawaited(_playIndex(0));
        }
      case LoopMode.off:
        final next = _currentIndex + 1;
        if (next < _queue.length) {
          unawaited(_playIndex(next));
        } else {
          _log('LoopMode.off → end of queue, stopping');
          cancelSleepTimer();
        }
    }
  }

  // ===== Boost / громкость =====

  Future<void> _initBoost() async {
    try {
      final saved = await _env.getSetting(_boostDbKey);
      final db = saved == null ? null : double.tryParse(saved);
      if (db != null) {
        _boostDb.add(db.clamp(0.0, kMaxBoostDb));
        await _applyBoost();
      }
    } catch (e) {
      _log('boost init failed: $e');
    }
  }

  @override
  void setBoost(double db) {
    final clamped = db.clamp(0.0, kMaxBoostDb);
    _boostDb.add(clamped);
    unawaited(_applyBoost());
    unawaited(_env
        .setSetting(_boostDbKey, clamped.toString())
        .catchError((Object _) {}));
  }

  Future<void> _applyBoost() async {
    try {
      await _backend.setBoost(_boostDb.value);
    } catch (e) {
      _log('setBoost failed: $e');
    }
  }

  Future<void> _initVolume() async {
    try {
      final saved = await _env.getSetting(_volumeKey);
      final v = saved == null ? null : double.tryParse(saved);
      if (v != null) await setVolume(v);
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double volume) async {
    final c = volume.clamp(0.0, 1.0);
    _volume.add(c);
    try {
      await _backend.setVolume(c);
    } catch (_) {}
    if (_persistVolume) {
      unawaited(
          _env.setSetting(_volumeKey, c.toString()).catchError((Object _) {}));
    }
  }

  // ===== Очередь =====

  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _notifyQueue();
    if (_queue.isEmpty) {
      _loadGeneration++;
      _isLoading = false;
      _pendingHistoryTrack = null;
      _setCurrentIndex(-1);
      try {
        await _backend.stop();
      } catch (_) {}
      _scheduleSessionSave();
      return;
    }
    // _playIndex сам сохраняет сессию.
    await _playIndex(startIndex.clamp(0, _queue.length - 1));
  }

  @override
  Future<void> playIndex(int index) => _playIndex(index);

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index);

  @override
  Future<void> addToQueue(Track track) async {
    _queue.add(track);
    _notifyQueue();
    _scheduleSessionSave();
  }

  @override
  Future<void> insertToQueue(Track track) async {
    final insertIndex = _currentIndex >= 0 ? _currentIndex + 1 : 0;
    _queue.insert(min(insertIndex, _queue.length), track);
    _notifyQueue();
    _scheduleSessionSave();
  }

  /// Удаление играющего трека останавливает воспроизведение.
  @override
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _setCurrentIndex(_currentIndex - 1);
    } else if (index == _currentIndex) {
      _loadGeneration++;
      _isLoading = false;
      _pendingHistoryTrack = null;
      _setCurrentIndex(-1);
      try {
        await _backend.stop();
      } catch (_) {}
    }
    _notifyQueue();
    _scheduleSessionSave();
  }

  @override
  Future<void> clearQueue() async {
    _loadGeneration++;
    _isLoading = false;
    _prefetchTimer?.cancel();
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = null;
    _sessionDirty = false;
    _pendingHistoryTrack = null;
    try {
      await _backend.stop();
    } catch (_) {}
    _queue.clear();
    _setCurrentIndex(-1);
    _notifyQueue();
    _emitMediaItem(null);
    _emitPlaybackState();
    // Пустую сессию пишем явно: flush пропускает idle-плеер без изменений,
    // и после рестарта вернулась бы старая очередь.
    try {
      await _env.saveSession(queue: const [], currentIndex: -1, positionMs: 0);
    } catch (e) {
      _log('clear session: $e');
    }
  }

  @override
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;
    if (oldIndex == newIndex) return;

    final track = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, track);

    if (oldIndex == _currentIndex) {
      _setCurrentIndex(newIndex);
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _setCurrentIndex(_currentIndex - 1);
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _setCurrentIndex(_currentIndex + 1);
    }
    _notifyQueue();
    _scheduleSessionSave();
  }

  /// Перемешивает очередь; играющий трек становится первым.
  @override
  Future<void> shuffleQueue({Random? random}) async {
    if (_queue.length < 2) return;
    final current = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    _queue.shuffle(random ?? Random());
    if (current != null) {
      _queue.remove(current);
      _queue.insert(0, current);
      _setCurrentIndex(0);
    }
    _notifyQueue();
    _scheduleSessionSave();
  }

  @override
  Future<void> setLoopMode(LoopMode mode) async {
    // Бэкенд всегда играет один трек: one/all/off обрабатывает
    // _onTrackFinished.
    _loopMode.add(mode);
  }

  @override
  Future<void> cycleLoopMode() => setLoopMode(switch (_loopMode.value) {
        LoopMode.off => LoopMode.all,
        LoopMode.all => LoopMode.one,
        LoopMode.one => LoopMode.off,
      });

  // ===== Загрузка трека =====

  int _consecutiveSkips = 0;
  static const int _maxConsecutiveSkips = 5;

  Future<void> _playIndex(int index, {bool isRetry = false}) async {
    if (index < 0 || index >= _queue.length) return;

    final myGen = ++_loadGeneration;
    _isLoading = true;
    _pendingHistoryTrack = null;
    _setCurrentIndex(index);
    final track = _queue[index];
    _log('[$myGen] Playing index=$index "${track.title}" '
        'id=${track.id} src=${track.sourceId}${isRetry ? ' (RETRY)' : ''}');

    _emitMediaItem(PlayerConversions.toMediaItem(track));
    _env.protectCache(track);

    try {
      await _backend.stop();
    } catch (_) {}

    try {
      final sw = Stopwatch()..start();
      final source = await _env.resolve(track);
      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after resolve');
        return;
      }
      _log('[$myGen] $source ready in ${sw.elapsedMilliseconds} ms');

      await _backend.load(source, tag: track.globalId);
      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after load');
        return;
      }

      _isLoading = false;
      _consecutiveSkips = 0;
      _pendingHistoryTrack = track;
      _log('[$myGen] loaded (${sw.elapsedMilliseconds} ms total), playing');
      await _backend.play();
      unawaited(_applyBoost());
      _scheduleSessionSave();
      _warmArtwork(index);
      _schedulePrefetchNext(myGen);
    } catch (e, st) {
      if (myGen != _loadGeneration) return;
      _isLoading = false;
      _log('[$myGen] PLAYBACK ERROR: $e\n$st');

      if (!isRetry && _env.isRetryable(e)) {
        _log('[$myGen] evicting cache and retrying');
        try {
          await _env.evictCache(track);
        } catch (_) {}
        if (myGen != _loadGeneration) return;
        _loadGeneration = myGen - 1;
        await _playIndex(index, isRetry: true);
      } else {
        _log('[$myGen] track unavailable, skipping');
        _skipAfterError(index);
      }
    }
  }

  void _skipAfterError(int failedIndex) {
    _consecutiveSkips++;
    if (_consecutiveSkips > _maxConsecutiveSkips) {
      _log('Too many consecutive skips ($_consecutiveSkips), giving up');
      _consecutiveSkips = 0;
      return;
    }
    final next = failedIndex + 1;
    if (next < _queue.length) {
      unawaited(_playIndex(next));
    } else if (failedIndex > 0) {
      _log('End of queue after error, going back to ${failedIndex - 1}');
      unawaited(_playIndex(failedIndex - 1));
    } else {
      _consecutiveSkips = 0;
    }
  }

  Timer? _prefetchTimer;
  static const Duration _prefetchDelay = Duration(seconds: 5);

  void _schedulePrefetchNext(int gen) {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(_prefetchDelay, () {
      if (gen != _loadGeneration) return;
      final nextIdx = _currentIndex + 1;
      if (nextIdx < 0 || nextIdx >= _queue.length) return;
      final next = _queue[nextIdx];
      unawaited(() async {
        try {
          await _env.prefetch(next);
          if (gen == _loadGeneration) {
            _log('[$gen] prefetched next: "${next.title}"');
          }
        } catch (_) {}
      }());
    });
  }

  // ===== Транспорт =====

  @override
  Future<void> play() async {
    if (_isLoading) {
      _log('play() ignored (loading)');
      return;
    }
    // Источник не загружен (например, после восстановления сессии) —
    // загружаем текущий трек, _playIndex сам запустит воспроизведение.
    if (_backend.processingState == AudioProcessingState.idle &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      _log('play() on idle backend — loading index=$_currentIndex');
      await _playIndex(_currentIndex);
      return;
    }
    try {
      await _backend.play();
    } catch (e) {
      _log('play() error: $e');
    }
    _scheduleSessionSave();
  }

  @override
  Future<void> pause() async {
    try {
      await _backend.pause();
    } catch (e) {
      _log('pause() error: $e');
    }
    // Мгновенный flush с актуальной позицией — после паузы debounce не нужен.
    await _flushSessionNow(force: true);
  }

  @override
  Future<void> stop() async {
    try {
      await _backend.stop();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _backend.seek(position);
    } catch (e) {
      _log('seek($position) failed: $e');
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_currentIndex + 1 < _queue.length) {
      await _playIndex(_currentIndex + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_backend.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_currentIndex - 1 >= 0) {
      await _playIndex(_currentIndex - 1);
    }
  }

  // ===== Обложки =====

  /// Прогревает обложки текущего и следующего трека и лениво обновляет их
  /// через провайдер (свежий URL отдаётся из кэша без сети, устаревший
  /// перезапрашивается — так подхватывается смена обложки в Genius).
  void _warmArtwork(int index) {
    for (final i in [index, index + 1]) {
      if (i < 0 || i >= _queue.length) continue;
      final track = _queue[i];
      final url = track.artworkUrl;
      if (url != null && url.isNotEmpty) _env.precacheArtwork(url);
      _fetchAndApplyArtwork(track, i);
    }
  }

  void _fetchAndApplyArtwork(Track track, int queueIndex) {
    if (!_env.needsArtworkRefresh(track)) return;
    _env.fetchArtworkUrl(track).then((url) {
      if (url == null || url.isEmpty) return;
      if (queueIndex < 0 || queueIndex >= _queue.length) return;
      // Сверяемся с актуальной записью очереди: пока URL летел из сети,
      // очередь могла измениться или обложка — обновиться другим вызовом.
      final current = _queue[queueIndex];
      if (current.globalId != track.globalId) return;
      if (current.artworkUrl == url) return;

      final updated = current.copyWith(artworkUrl: url);
      _queue[queueIndex] = updated;
      // mediaItem — только для активного трека, иначе шторка уведомлений
      // может на секунду показать обложку следующего.
      if (queueIndex == _currentIndex) {
        _emitMediaItem(PlayerConversions.toMediaItem(updated));
      }
      _notifyQueue();
      _env.persistArtwork(current.globalId, url);
    }).catchError((Object _) {});
  }

  @override
  Future<void> updateCustomArtwork(String trackId, String newPath) async {
    final globalId = _replaceQueueArtwork(trackId, newPath);
    _replaceCurrentArtUri(trackId, Uri.file(newPath));
    if (globalId != null && globalId.isNotEmpty) {
      _env.persistArtwork(globalId, newPath);
    }
  }

  @override
  Future<void> resetCustomArtwork(String trackId) async {
    await _env.removeCustomArtwork(trackId);
    // Оригинальный URL живёт в extras текущего MediaItem: в очереди после
    // updateCustomArtwork уже лежит путь к кастомному файлу.
    String? original;
    final current = _mediaItemSubject.value;
    if (current != null && _trackIdOf(current) == trackId) {
      original = current.extras?['originalArtworkUrl'] as String?;
    }
    final globalId = _replaceQueueArtwork(trackId, original);
    _replaceCurrentArtUri(
        trackId, original != null ? Uri.tryParse(original) : null);
    if (globalId != null && globalId.isNotEmpty && original != null) {
      _env.persistArtwork(globalId, original);
    }
  }

  /// Меняет обложку всех вхождений трека в очереди; возвращает его globalId
  /// (null — трека в очереди нет).
  String? _replaceQueueArtwork(String trackId, String? artworkUrl) {
    String? globalId;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = _queue[i].copyWith(artworkUrl: artworkUrl);
        globalId = _queue[i].globalId;
      }
    }
    if (globalId != null) _notifyQueue();
    return globalId;
  }

  String _trackIdOf(MediaItem m) => m.extras?['trackId'] as String? ?? m.id;

  void _replaceCurrentArtUri(String trackId, Uri? artUri) {
    final current = _mediaItemSubject.value;
    if (current == null || _trackIdOf(current) != trackId) return;
    _emitMediaItem(MediaItem(
      id: current.id,
      title: current.title,
      artist: current.artist,
      duration: current.duration,
      artUri: artUri,
      extras: Map<String, dynamic>.from(current.extras ?? const {}),
    ));
  }

  // ===== Сессия =====
  // Короткий debounce: частые мутации очереди/плеера (play, next, add)
  // сливаются в одно сохранение. Принудительный flush — при pause(),
  // saveSession() (сворачивание / закрытие окна) и dispose().

  static const Duration _sessionSaveDebounce = Duration(milliseconds: 300);
  Timer? _sessionSaveTimer;
  bool _sessionDirty = false;
  int? _pendingPositionMs;

  /// Последняя позиция запоминается в момент планирования, чтобы flush не
  /// потерял свежий seek/play.
  void _scheduleSessionSave() {
    if (_sessionDirty && _sessionSaveTimer != null) return;
    _pendingPositionMs = _backend.position.inMilliseconds;
    _sessionDirty = true;
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = Timer(_sessionSaveDebounce, () {
      _sessionSaveTimer = null;
      unawaited(_flushSessionNow());
    });
  }

  /// [force] — сохранить даже без отложенных изменений (позиция меняется
  /// постоянно, а флаг dirty её не отслеживает). Пропускаем только idle-плеер
  /// без изменений: восстановленная, но не запущенная сессия (или ещё не
  /// восстановленная — пустая очередь) не должна перезаписывать сохранённую.
  Future<void> _flushSessionNow({bool force = false}) async {
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = null;
    final dirty = _sessionDirty;
    _sessionDirty = false;
    final pendingPos = _pendingPositionMs;
    _pendingPositionMs = null;
    if (!dirty &&
        (!force || _backend.processingState == AudioProcessingState.idle)) {
      return;
    }
    try {
      final pos = force
          ? _backend.position.inMilliseconds
          : pendingPos ?? _backend.position.inMilliseconds;
      await _env.saveSession(
        queue: List.of(_queue),
        currentIndex: _currentIndex,
        positionMs: pos,
      );
    } catch (e) {
      // Ошибка БД не должна ронять плеер.
      _log('save session: $e');
    }
  }

  @override
  Future<void> saveSession() => _flushSessionNow(force: true);

  Future<void> _restoreSession() async {
    try {
      final session = await _env.loadSession();
      if (session == null) return;
      // Пользователь успел собрать новую очередь до конца восстановления.
      if (_queue.isNotEmpty || _loadGeneration > 0) return;
      _log('Restoring session: ${session.queue.length} tracks, '
          'index=${session.currentIndex}');

      _queue
        ..clear()
        ..addAll(session.queue);
      _setCurrentIndex(session.currentIndex.clamp(-1, _queue.length - 1));
      _notifyQueue();

      if (_currentIndex >= 0) {
        // Показываем трек в UI сразу, не дожидаясь сетевого resolve:
        // источник загрузится при нажатии Play (см. [play]).
        _emitMediaItem(PlayerConversions.toMediaItem(_queue[_currentIndex]));
        if (!_playbackStateSubject.isClosed) {
          _playbackStateSubject.add(PlaybackState(
            controls: [MediaControl.play],
            processingState: AudioProcessingState.ready,
            playing: false,
            queueIndex: _currentIndex,
          ));
        }
      }
    } catch (e, st) {
      _log('Session restore failed: $e\n$st');
    }
  }

  /// Сохраняет сессию и освобождает бэкенд.
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _prefetchTimer?.cancel();
    await _flushSessionNow(force: true);
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _backend.dispose();
    await _currentIndexSubject.close();
    await _queueSubject.close();
    await _mediaItemSubject.close();
    await _playbackStateSubject.close();
    await _loopMode.close();
    await _boostDb.close();
    await _volume.close();
    await _sleepTimerMode.close();
    await _sleepTimerEndTime.close();
  }
}
