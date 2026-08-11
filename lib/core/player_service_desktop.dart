// lib/core/player_service_desktop.dart
// Desktop player — Windows / macOS / Linux. Pure just_audio, no audio_service.

import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models/track.dart';
import '../sources/source_registry.dart';
import 'app_database.dart';
import 'history_repository.dart';
import 'playlist_repository.dart';
import 'youtube_cache.dart';
import 'player_service.dart' show SleepTimerMode;
import 'player_service_interface.dart';

void _log(String msg) => debugPrint('[DesktopPlayer] $msg');

class DesktopPlayerService implements PlayerServiceInterface {
  // ===== Fields =====
  static const _boostDbKey = 'boost_db_v1';
  final _boostDb = BehaviorSubject<double>.seeded(0.0);

  @override double get boostDb => _boostDb.value;
  @override Stream<double> get boostDbStream => _boostDb.stream;

  late final AudioPlayer _player;
  StreamSubscription<Duration>? _positionSub;
  final List<Track> _queue = [];
  int _currentIndex = -1;

  // ===== История прослушивания =====
  // Записываем трек в историю только после того, как он реально отыграл
  // хотя бы [_historyThreshold] и продолжает играть. Это защищает от
  // «фантомных» записей при ошибках и мгновенных скипах.
  Track? _pendingHistoryTrack;
  static const Duration _historyThreshold = Duration(seconds: 1);

  @override int get currentIndex => _currentIndex;
  final _currentIndexSubject = BehaviorSubject<int>.seeded(-1);
  @override Stream<int> get currentIndexStream => _currentIndexSubject.stream;

  final _loopMode = BehaviorSubject<LoopMode>.seeded(LoopMode.off);
  @override LoopMode get loopMode => _loopMode.value;
  @override Stream<LoopMode> get loopModeStream => _loopMode.stream;

  int _loadGeneration = 0;
  bool _isLoading = false;
  @override bool get isLoading => _isLoading;

  final _sleepTimerMode = BehaviorSubject<SleepTimerMode>.seeded(SleepTimerMode.off);
  @override SleepTimerMode get sleepTimerMode => _sleepTimerMode.value;
  @override Stream<SleepTimerMode> get sleepTimerModeStream => _sleepTimerMode.stream;

  final _sleepTimerEndTime = BehaviorSubject<DateTime?>.seeded(null);
  @override DateTime? get sleepTimerEndTime => _sleepTimerEndTime.value;
  @override Stream<DateTime?> get sleepTimerEndTimeStream => _sleepTimerEndTime.stream;

  final _mediaItemSubject = BehaviorSubject<MediaItem?>.seeded(null);
  @override Stream<MediaItem?> get mediaItem => _mediaItemSubject.stream;
  @override MediaItem? get mediaItemValue => _mediaItemSubject.value;

  final _playbackStateSubject = BehaviorSubject<PlaybackState>();
  @override Stream<PlaybackState> get playbackState => _playbackStateSubject.stream;

  @override List<Track> get trackQueue => List.unmodifiable(_queue);

  Timer? _sleepTimer, _prefetchTimer;
  static const _prefetchDelay = Duration(seconds: 5);
  bool _isHandlingTrackFinish = false;
  int _consecutiveSkips = 0;
  static const _maxConsecutiveSkips = 5;

  @override Stream<Duration> get positionStream => _player.positionStream;
  @override Stream<Duration?> get durationStream => _player.durationStream;
  @override Stream<bool> get playingStream => _player.playingStream;
  @override AudioPlayer get rawPlayer => _player;

  DesktopPlayerService() {
    // На десктопе (Windows/Linux/macOS) audio_session не реализован —
    // отключаем его активацию, чтобы just_audio не дёргал отсутствующий
    // плагин в play(). На мобильных это поведение не затрагивается.
    _player = AudioPlayer(handleAudioSessionActivation: false);
    _player.playerStateStream.listen(onPlayerState);
    _player.playbackEventStream.listen(_onPlaybackEvent);
    // Подписка на позицию — для записи истории прослушивания.
    _positionSub = _player.positionStream.listen((pos) {
      final pending = _pendingHistoryTrack;
      if (pending == null) return;
      if (!_player.playing) return;
      if (pos < _historyThreshold) return;
      _pendingHistoryTrack = null;
      // Берём актуальную версию трека из очереди — к этому моменту
      // artworkUrl мог обновиться.
      final currentTrack = _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : pending;
      unawaited(HistoryRepository.instance.add(currentTrack));
    });
    _initBoost();
    _restoreSession();
  }

  void dispose() {
    _positionSub?.cancel();
    _sleepTimer?.cancel();
    _prefetchTimer?.cancel();
    _sleepTimerMode.close();
    _sleepTimerEndTime.close();
    _mediaItemSubject.close();
    _playbackStateSubject.close();
    _boostDb.close();
    _currentIndexSubject.close();
    _loopMode.close();
  }

  void _onPlaybackEvent(PlaybackEvent event) {
    _emitPlaybackState();
  }

  /// Публикует актуальное состояние воспроизведения в UI.
  ///
  /// Вызывается и из [playbackEventStream], и из [playerStateStream]
  /// (объединяет playing + processingState). Второе критично на Windows:
  /// нативные команды системного медиа-бара (SMTC) меняют [AudioPlayer.playing]
  /// через data-события, которые НЕ проходят через playbackEventStream, —
  /// без этого кнопка play/pause застревала бы в устаревшем состоянии
  /// («инверсия» между тем, что показывает приложение, и тем, что реально
  /// играет).
  void _emitPlaybackState() {
    if (_playbackStateSubject.isClosed) return;
    _playbackStateSubject.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward,
      },
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex >= 0 ? _currentIndex : null,
    ));
  }

  // ===== Boost =====
  Future<void> _initBoost() async {
    try {
      final raw = await AppDatabase.instance.getSetting(_boostDbKey);
      if (raw != null) {
        final v = double.tryParse(raw);
        if (v != null) _boostDb.add(v.clamp(0.0, kMaxBoostDb));
      }
    } catch (_) {}
  }

  @override
  void setBoost(double db) {
    final c = db.clamp(0.0, kMaxBoostDb);
    _boostDb.add(c);
    unawaited(AppDatabase.instance.setSetting(_boostDbKey, c.toString()));
  }

  // ===== Sleep Timer =====
  @override void startSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.time);
    _sleepTimerEndTime.add(DateTime.now().add(d));
    _sleepTimer = Timer(d, () async {
      _sleepTimerMode.add(SleepTimerMode.endOfTrack);
      _sleepTimerEndTime.add(null);
      try { await _player.setLoopMode(LoopMode.off); } catch (_) {}
    });
  }
  @override Future<void> setStopAtEndOfSong() async {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.endOfTrack);
    _sleepTimerEndTime.add(null);
    try { await _player.setLoopMode(LoopMode.off); } catch (_) {}
  }
  @override void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.off);
    _sleepTimerEndTime.add(null);
  }

  // ===== Queue =====
  @override Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue..clear()..addAll(tracks);
    if (_queue.isEmpty) {
      // Защита от ArgumentError: startIndex.clamp(0, -1) при пустой очереди.
      _currentIndex = -1;
      _currentIndexSubject.add(-1);
      _pendingHistoryTrack = null;
      await _player.stop();
      await _saveSession();
      return;
    }
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    _currentIndexSubject.add(_currentIndex);
    await _playIndex(_currentIndex);
  }
  @override Future<void> playIndex(int i) => _playIndex(i);
  @override Future<void> addToQueue(Track t) async { _queue.add(t); await _saveSession(); }
  @override Future<void> insertToQueue(Track t) async {
    final p = _currentIndex + 1;
    if (p <= _queue.length) {
      _queue.insert(p, t);
    } else {
      _queue.add(t);
    }
    await _saveSession();
  }
  @override Future<void> removeFromQueue(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _queue.removeAt(i);
    if (i < _currentIndex) {
      _currentIndex--;
    } else if (i == _currentIndex && _queue.isNotEmpty) {
      _currentIndex = _currentIndex.clamp(0, _queue.length - 1);
    }
    _currentIndexSubject.add(_currentIndex);
    await _saveSession();
  }
  Future<void> clearQueue() async {
    await _player.stop(); _queue.clear(); _currentIndex = -1;
    _currentIndexSubject.add(_currentIndex); await _saveSession();
  }
  @override Future<void> reorderQueueItem(int o, int n) async {
    if (o < 0 || o >= _queue.length || n < 0 || n >= _queue.length || o == n) return;
    final t = _queue.removeAt(o); _queue.insert(n, t);
    if (o == _currentIndex) {
      _currentIndex = n;
    } else if (o < _currentIndex && n >= _currentIndex) {
      _currentIndex--;
    } else if (o > _currentIndex && n <= _currentIndex) {
      _currentIndex++;
    }
    _currentIndexSubject.add(_currentIndex); await _saveSession();
  }
  @override Future<void> shuffleQueue() async {
    if (_queue.length < 2) return;
    final cur = _currentIndex >= 0 && _currentIndex < _queue.length ? _queue[_currentIndex] : null;
    final rng = Random();
    for (var i = _queue.length - 1; i > 0; i--) { final j = rng.nextInt(i + 1); final t = _queue[i]; _queue[i] = _queue[j]; _queue[j] = t; }
    if (cur != null) { final idx = _queue.indexOf(cur); if (idx > 0) { _queue.removeAt(idx); _queue.insert(0, cur); } _currentIndex = 0; _currentIndexSubject.add(_currentIndex); }
    await _saveSession();
  }

  // ===== Loop =====
  @override Future<void> setLoopMode(LoopMode m) async { _loopMode.add(m); await _player.setLoopMode(LoopMode.off); }
  @override Future<void> cycleLoopMode() {
    final n = switch (_loopMode.value) { LoopMode.off => LoopMode.all, LoopMode.all => LoopMode.one, LoopMode.one => LoopMode.off };
    return setLoopMode(n);
  }

  // ===== Playback =====
  @override Future<void> play() async {
    if (_isLoading) return;
    if (_player.processingState == ProcessingState.idle &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      await _playIndex(_currentIndex);
      return;
    }
    try {
      await _player.play();
    } catch (e, st) {
      _log('play: $e\n$st');
    }
    if (!_player.playing &&
        !_isLoading &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      // just_audio мог проигнорировать команду (деактивированная платформа —
      // no-op _IdleAudioPlayer на Windows). Перезагружаем трек: setAudioSource
      // принудительно активирует нативную платформу заново.
      _log('play: force reload to re-activate native platform');
      await _playIndex(_currentIndex);
      return;
    }
    _emitPlaybackState();
    await _saveSession();
  }
  @override Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e, st) {
      _log('pause: $e\n$st');
    }
    _emitPlaybackState();
    await _saveSession();
  }
  @override Future<void> seek(Duration p) async { try { await _player.seek(p); } catch (e) { _log('seek: $e'); } }
  @override Future<void> skipToNext() async {
    if (_currentIndex + 1 < _queue.length) {
      await _playIndex(_currentIndex + 1);
      _emitPlaybackState();
    }
  }
  @override Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_currentIndex - 1 >= 0) {
      await _playIndex(_currentIndex - 1);
      _emitPlaybackState();
    }
  }
  @override Future<void> skipToQueueItem(int i) => _playIndex(i);

  // ===== Core playback =====
  Future<void> _playIndex(int index, {bool isRetry = false}) async {
    if (index < 0 || index >= _queue.length) return;
    _isLoading = true; _isHandlingTrackFinish = false;
    _pendingHistoryTrack = null;
    final gen = ++_loadGeneration;
    _currentIndex = index; _currentIndexSubject.add(index);
    final track = _queue[index];
    _emitMediaItem(track);
    _log('[$gen] play $index "${track.title}" ${isRetry ? "(RETRY)" : ""}');
    try {
      final src = SourceRegistry.instance.require(track.sourceId);
      final sw = Stopwatch()..start();
      final srcAudio = await src.createAudioSource(track);
      if (gen != _loadGeneration) return;
      _log('[$gen] ready ${sw.elapsedMilliseconds}ms');
      await _player.setAudioSource(srcAudio, preload: true);
      if (gen != _loadGeneration) return;
      _isLoading = false; _consecutiveSkips = 0;
      _pendingHistoryTrack = track;
      await _player.play(); await _saveSession();
      // На Windows платформа может быть деактивирована — play() не
      // активирует воспроизведение (no-op _IdleAudioPlayer). Принудительно
      // перезагружаем трек, чтобы гарантировать реальный звук, а не
      // «пустоту» при переключении next/prev.
      if (!_player.playing && gen == _loadGeneration) {
        _log('[$gen] play after switch: no audio, force reload');
        _loadGeneration = gen - 1;
        await _playIndex(index, isRetry: true);
        return;
      }
      _emitPlaybackState();
      _schedulePrefetchNext(gen);
    } catch (e, st) {
      if (gen != _loadGeneration) return;
      _isLoading = false;
      _log('[$gen] ERROR: $e\n$st');
      if (!isRetry) {
        final cid = YoutubeCache.cacheIdFor(sourceId: track.sourceId, trackId: track.id);
        await YoutubeCache.instance.evict(cid);
        _loadGeneration = gen - 1;
        await _playIndex(index, isRetry: true);
      } else {
        _skipAfterError(index);
      }
    }
  }
  void _skipAfterError(int fi) {
    _consecutiveSkips++;
    if (_consecutiveSkips > _maxConsecutiveSkips) { _consecutiveSkips = 0; return; }
    final n = fi + 1;
    if (n < _queue.length) {
      _playIndex(n);
    } else if (fi > 0) {
      _playIndex(fi - 1);
    }
  }
  void _schedulePrefetchNext(int gen) {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(_prefetchDelay, () {
      if (gen != _loadGeneration) return;
      final n = _currentIndex + 1;
      if (n < 0 || n >= _queue.length) return;
      final nt = _queue[n];
      final src = SourceRegistry.instance.require(nt.sourceId);
      unawaited(() async {
        try {
          await src.prefetch(nt);
          if (gen == _loadGeneration) {
            _log('[$gen] prefetched "${nt.title}"');
          }
        } catch (_) {}
      }());
    });
  }

  // ===== Events =====
  void onPlayerState(PlayerState s) {
    // Синхронизируем UI с любым изменением playing/processingState,
    // включая изменения, пришедшие из нативных data-событий (SMTC-бар).
    _emitPlaybackState();
    if (s.processingState == ProcessingState.completed && !_isLoading) {
      onTrackFinished();
    }
  }

  void onTrackFinished() {
    if (_isHandlingTrackFinish) return;
    _isHandlingTrackFinish = true;
    try {
      if (sleepTimerMode == SleepTimerMode.endOfTrack) {
        cancelSleepTimer();
        return;
      }
      switch (_loopMode.value) {
        case LoopMode.one:
          _playIndex(_currentIndex);
        case LoopMode.all:
          final n = _currentIndex + 1;
          if (n < _queue.length) {
            _playIndex(n);
          } else if (_queue.isNotEmpty) {
            _playIndex(0);
          }
        case LoopMode.off:
          final n = _currentIndex + 1;
          if (n < _queue.length) {
            _playIndex(n);
          } else {
            cancelSleepTimer();
          }
      }
    } finally {
      _isHandlingTrackFinish = false;
    }
  }

  // ===== Artwork =====
  @override
  Future<void> updateCustomArtwork(String tid, String p) async {
    String? gid;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == tid) {
        _queue[i] = _queue[i].copyWith(artworkUrl: p);
        gid = _queue[i].globalId;
      }
    }
    if (gid != null && gid.isNotEmpty) {
      unawaited(PlaylistRepository.instance.updateTrackArtwork(gid, p));
      unawaited(HistoryRepository.instance.updateTrackArtwork(gid, p));
    }
  }

  @override
  Future<void> resetCustomArtwork(String tid) async {
    String? gid;
    String? orig;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == tid) {
        orig = _queue[i].artworkUrl;
        _queue[i] = _queue[i].copyWith(artworkUrl: orig);
        gid = _queue[i].globalId;
      }
    }
    if (gid != null && orig != null && gid.isNotEmpty) {
      unawaited(PlaylistRepository.instance.updateTrackArtwork(gid, orig));
      unawaited(HistoryRepository.instance.updateTrackArtwork(gid, orig));
    }
  }

  // ===== Session =====
  @override
  Future<void> saveSession() async => _saveSession();

  Future<void> _saveSession() async {
    if (_queue.isEmpty) return;
    try {
      final queueRows = _queue.map((t) => t.toMap()).toList();
      await AppDatabase.instance.savePlaybackSession(
        queueRows: queueRows,
        currentIndex: _currentIndex,
        positionMs: _player.position.inMilliseconds,
      );
    } catch (e) {
      _log('save session: $e');
    }
  }

  Future<void> _restoreSession() async {
    try {
      final s = await AppDatabase.instance.loadPlaybackSession();
      if (s == null) return;
      _queue
        ..clear()
        ..addAll(s.queue);
      _currentIndex = s.currentIndex.clamp(-1, _queue.length - 1);
      _currentIndexSubject.add(_currentIndex);
    } catch (e, st) {
      _log('restore: $e\n$st');
    }
  }

  // ===== MediaItem helpers =====
  MediaItem _toMediaItem(Track t) {
    return MediaItem(
      id: t.globalId,
      title: t.title,
      artist: t.artist,
      duration: t.duration,
      artUri: t.artworkUrl != null ? Uri.tryParse(t.artworkUrl!) : null,
      extras: {
        'sourceId': t.sourceId,
        'trackId': t.id,
        'originalArtworkUrl': t.artworkUrl,
      },
    );
  }

  void _emitMediaItem(Track t) => _mediaItemSubject.add(_toMediaItem(t));

  @override
  Future<void> stop() async => await _player.stop();
}