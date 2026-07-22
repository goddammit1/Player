import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' show ImageConfiguration, ImageStreamListener;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../sources/source_registry.dart';
import 'youtube_cache.dart';

// print -> adb logcat (tag: flutter)
// ignore: avoid_print
void _log(String msg) => print('[PlayerService] $msg');

class PlayerService extends BaseAudioHandler with SeekHandler {
  // ===== BOOST =====
  //
  // Обычная громкость полностью отдана системному регулятору
  // (STREAM_MUSIC) — мы её не трогаем. Единственное, чем управляет
  // приложение, — это "буст": усиление поверх системного уровня через
  // AndroidLoudnessEnhancer. Эффект встроен в AudioPipeline плеера,
  // который работает в фоновом аудиосервисе, поэтому буст сохраняется,
  // когда приложение свёрнуто, без какой-либо возни с lifecycle.

  static const String _boostDbKey = 'boost_db_v1';

  /// Потолок буста в децибелах. 0 dB = без усиления.
  static const double maxBoostDb = 12.0;

  /// Текущий буст в дБ (0..maxBoostDb).
  final BehaviorSubject<double> _boostDb = BehaviorSubject<double>.seeded(0.0);
  Stream<double> get boostDbStream => _boostDb.stream;
  double get boostDb => _boostDb.value;

  late final AndroidLoudnessEnhancer _loudnessEnhancer;
  late final AudioPlayer _player;

  final List<Track> _queue = [];
  int _currentIndex = -1;

  final BehaviorSubject<LoopMode> _loopMode =
      BehaviorSubject<LoopMode>.seeded(LoopMode.off);
  Stream<LoopMode> get loopModeStream => _loopMode.stream;
  LoopMode get loopMode => _loopMode.value;

  final BehaviorSubject<int> _currentIndexSubject =
      BehaviorSubject<int>.seeded(-1);
  Stream<int> get currentIndexStream => _currentIndexSubject.stream;
  int get currentIndex => _currentIndex;

  int _loadGeneration = 0;
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  PlayerService() {
    _loudnessEnhancer = AndroidLoudnessEnhancer();

    _player = AudioPlayer(
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 15),
          maxBufferDuration: Duration(seconds: 30),
          bufferForPlaybackDuration: Duration(milliseconds: 1500),
          bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 800),
        ),
      ),
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_loudnessEnhancer],
      ),
    );

    _player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object e, StackTrace st) {
        _log('playbackEventStream error: $e');
      },
    );

    _player.playerStateStream.listen(
      (state) {
        if (state.processingState == ProcessingState.completed) {
          if (_isLoading) {
            _log('completed ignored (already loading gen=$_loadGeneration)');
            return;
          }

          final pos = _player.position;
          final dur = _player.duration ?? Duration.zero;
          if (dur > Duration.zero && pos >= dur - const Duration(seconds: 1)) {
            _onTrackFinished();
          }
        }
      },
      onError: (Object e, StackTrace st) {
        _log('playerStateStream error: $e');
      },
    );

    unawaited(_initBoost());
  }

  // ===== BOOST METHODS =====

  Future<void> _initBoost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_boostDbKey) ?? 0.0;
      await setBoost(saved);
    } catch (e) {
      _log('boost init failed: $e');
    }
  }

  /// Единственная точка управления бустом (слайдер в UI).
  /// Значение в дБ, 0..maxBoostDb. Персистится в prefs и переживает
  /// перезапуск приложения; в фоне держится самим audio pipeline.
  Future<void> setBoost(double db) async {
    final clamped = db.clamp(0.0, maxBoostDb);
    _boostDb.add(clamped);
    try {
      await _loudnessEnhancer.setEnabled(true);
      await _loudnessEnhancer.setTargetGain(clamped);
      _log('setBoost($clamped dB) OK');
    } catch (e) {
      _log('setBoost FAILED: $e');
    }
    unawaited(_persistBoost(clamped));
  }

  Future<void> _persistBoost(double db) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_boostDbKey, db);
    } catch (_) {}
  }

  /// Повторно применяем буст к эффекту — на случай, если при смене
  /// аудио-сессии эффект был пересоздан.
  Future<void> _reapplyBoost() async {
    try {
      await _loudnessEnhancer.setEnabled(true);
      await _loudnessEnhancer.setTargetGain(_boostDb.value);
    } catch (_) {}
  }

  // ===== Авто-переход при завершении трека =====

  void _onTrackFinished() {
    switch (_loopMode.value) {
      case LoopMode.one:
        _log('LoopMode.one \u2192 replay index=$_currentIndex');
        _playIndex(_currentIndex);
      case LoopMode.all:
        final next = _currentIndex + 1;
        if (next < _queue.length) {
          _log('LoopMode.all \u2192 next index=$next');
          _playIndex(next);
        } else if (_queue.isNotEmpty) {
          _log('LoopMode.all \u2192 wrap to index=0');
          _playIndex(0);
        }
      case LoopMode.off:
        if (_currentIndex + 1 < _queue.length) {
          _log('LoopMode.off \u2192 next index=${_currentIndex + 1}');
          _playIndex(_currentIndex + 1);
        } else {
          _log('LoopMode.off \u2192 end of queue, stopping');
        }
    }
  }

  // ===== Queue =====

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index = _queue.indexWhere((t) => t.globalId == mediaItem.id);
    if (index < 0) return;

    _queue.removeAt(index);

    if (index < _currentIndex) {
      _currentIndex -= 1;
    } else if (index == _currentIndex) {
      _currentIndex = -1;
      _currentIndexSubject.add(-1);
      await _player.stop();
    }

    _currentIndexSubject.add(_currentIndex);
    queue.add(_queue.map(_toMediaItem).toList());
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _queue.length) return;

    _queue.removeAt(index);

    if (index < _currentIndex) {
      _currentIndex -= 1;
    } else if (index == _currentIndex) {
      _currentIndex = -1;
      _currentIndexSubject.add(-1);
      await _player.stop();
    }

    _currentIndexSubject.add(_currentIndex);
    queue.add(_queue.map(_toMediaItem).toList());
  }

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    queue.add(tracks.map(_toMediaItem).toList());
    if (tracks.isNotEmpty) {
      await _playIndex(startIndex);
    }
  }

  Future<void> addToQueue(Track track) async {
    _queue.add(track);
    queue.add([...queue.value, _toMediaItem(track)]);
  }

  Future<void> insertToQueue(Track track) async {
    final insertIndex = _currentIndex >= 0 ? _currentIndex + 1 : 0;
    _queue.insert(insertIndex, track);

    if (insertIndex <= _currentIndex) {
      _currentIndex += 1;
      _currentIndexSubject.add(_currentIndex);
    }

    queue.add(_queue.map(_toMediaItem).toList());
  }

  Future<void> _playIndex(int index, {bool isRetry = false}) async {
    if (index < 0 || index >= _queue.length) return;

    final myGen = ++_loadGeneration;
    _isLoading = true;
    _currentIndex = index;
    _currentIndexSubject.add(index);
    final track = _queue[index];
    _log('[$myGen] Playing index=$index track="${track.title}" '
        'id=${track.id} src=${track.sourceId}'
        '${isRetry ? ' (RETRY)' : ''}');

    mediaItem.add(_toMediaItem(track));

    // Защищаем файл текущего трека от эвикта/очистки, пока он играет.
    YoutubeCache.instance.setProtectedId(_cacheIdForTrack(track));

    try {
      await _player.stop();
    } catch (_) {}

    try {
      final source = SourceRegistry.instance.require(track.sourceId);
      _log('[$myGen] Resolving audio source...');
      final sw = Stopwatch()..start();

      final audioSource = await source.createAudioSource(track);

      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after resolve');
        return;
      }
      _log('[$myGen] AudioSource ready in ${sw.elapsedMilliseconds} ms');

      await _player.setAudioSource(audioSource, preload: true);

      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after setAudioSource');
        return;
      }

      _isLoading = false;
      _consecutiveSkips = 0;
      _log('[$myGen] setAudioSource OK (${sw.elapsedMilliseconds} ms total),'
          ' starting playback');
      await _player.play();

      // На случай пересоздания аудио-сессии повторно применяем буст.
      unawaited(_reapplyBoost());

      _warmArtwork(_currentIndex);
      _schedulePrefetchNext(myGen);
    } catch (e, st) {
      if (myGen != _loadGeneration) return;
      _isLoading = false;
      _log('[$myGen] PLAYBACK ERROR: $e');
      _log('Stack: $st');

      if (!isRetry) {
        _log('[$myGen] Evicting cache and retrying...');
        final cacheId = _cacheIdForTrack(track);
        await YoutubeCache.instance.evict(cacheId);
        _loadGeneration = myGen - 1;
        await _playIndex(index, isRetry: true);
      } else {
        _log('[$myGen] Track unavailable after retry, skipping...');
        _skipAfterError(index);
      }
    }
  }

  int _consecutiveSkips = 0;
  static const int _maxConsecutiveSkips = 5;

  void _skipAfterError(int failedIndex) {
    _consecutiveSkips++;
    if (_consecutiveSkips > _maxConsecutiveSkips) {
      _log('Too many consecutive skips ($_consecutiveSkips), giving up');
      _consecutiveSkips = 0;
      return;
    }

    final next = failedIndex + 1;
    if (next < _queue.length) {
      _log('Skipping to next after error: index=$next');
      _playIndex(next);
    } else if (failedIndex > 0) {
      _log('End of queue after error, going back to index=${failedIndex - 1}');
      _playIndex(failedIndex - 1);
    } else {
      _log('No tracks to skip to');
      _consecutiveSkips = 0;
    }
  }

  String _cacheIdForTrack(Track track) =>
      YoutubeCache.cacheIdFor(sourceId: track.sourceId, trackId: track.id);

  Timer? _prefetchTimer;
  static const Duration _prefetchDelay = Duration(seconds: 5);

  void _schedulePrefetchNext(int gen) {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(_prefetchDelay, () {
      if (gen != _loadGeneration) return;
      final nextIdx = _currentIndex + 1;
      if (nextIdx < 0 || nextIdx >= _queue.length) return;
      final next = _queue[nextIdx];
      final src = SourceRegistry.instance.require(next.sourceId);
      unawaited(() async {
        try {
          await src.prefetch(next);
          if (gen == _loadGeneration) {
            _log('[$gen] prefetched next: "${next.title}"');
          }
        } catch (_) {}
      }());
    });
  }

  // ===== audio_service controls =====

  @override
  Future<void> play() async {
    if (_isLoading) {
      _log('play() ignored (loading)');
      return;
    }
    await _player.play();
  }

  void _warmArtwork(int index) {
    if (index >= 0 && index < _queue.length) {
      final url = _queue[index].artworkUrl;
      if (url != null) _precacheImage(url);
    }
    final next = index + 1;
    if (next < _queue.length) {
      final url = _queue[next].artworkUrl;
      if (url != null) _precacheImage(url);
    }
  }

  void _precacheImage(String url) {
    final provider = CachedNetworkImageProvider(url);
    provider.resolve(ImageConfiguration.empty).addListener(
      ImageStreamListener((_, _) {}),
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
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
    if (_player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_currentIndex - 1 >= 0) {
      await _playIndex(_currentIndex - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index);

  // ===== Reorder / shuffle / repeat =====

  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;
    if (oldIndex == newIndex) return;

    final track = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, track);

    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex -= 1;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex += 1;
    }

    _currentIndexSubject.add(_currentIndex);
    queue.add(_queue.map(_toMediaItem).toList());
  }

  Future<void> shuffleQueue() async {
    if (_queue.length < 2) return;

    final current = _currentIndex >= 0 ? _queue[_currentIndex] : null;
    final rng = Random();
    for (var i = _queue.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = _queue[i];
      _queue[i] = _queue[j];
      _queue[j] = tmp;
    }

    if (current != null) {
      final idx = _queue.indexOf(current);
      if (idx > 0) {
        _queue.removeAt(idx);
        _queue.insert(0, current);
      }
      _currentIndex = 0;
      _currentIndexSubject.add(_currentIndex);
    }
    queue.add(_queue.map(_toMediaItem).toList());
  }

  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode.add(mode);
    await _player.setLoopMode(mode);
  }

  Future<void> cycleLoopMode() {
    final next = switch (_loopMode.value) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    return setLoopMode(next);
  }

  // ===== Streams =====

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  AudioPlayer get rawPlayer => _player;

  // ===== Helpers =====

  MediaItem _toMediaItem(Track t) => MediaItem(
        id: t.globalId,
        title: t.title,
        artist: t.artist,
        duration: t.duration,
        artUri: t.artworkUrl != null ? Uri.parse(t.artworkUrl!) : null,
        extras: {'sourceId': t.sourceId, 'trackId': t.id},
      );

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
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
    );
  }
}
