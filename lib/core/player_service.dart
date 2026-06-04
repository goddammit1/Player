import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models/track.dart';
import '../sources/source_registry.dart';

// print -> adb logcat (tag: flutter)
// ignore: avoid_print
void _log(String msg) => print('[PlayerService] $msg');

class PlayerService extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Поскольку весь трек кэшируется в локальный файл
        // (LockCachingAudioSource), огромный rolling-буфер в RAM
        // лишний — он только давит на GC при длинной очереди.
        // 15..30 секунд более чем достаточно для seek/rebuffer,
        // дальше данные читаются с диска мгновенно.
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 30),
        bufferForPlaybackDuration: Duration(milliseconds: 1500),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 800),
      ),
    ),
  );


  final List<Track> _queue = [];
  int _currentIndex = -1;

  // ===== Очередь / repeat — состояние и стримы =====

  /// Режим повтора (off / all / one). Вынесен из UI в сервис, чтобы
  /// окно очереди и нижняя панель показывали единое состояние.
  final BehaviorSubject<LoopMode> _loopMode =
      BehaviorSubject<LoopMode>.seeded(LoopMode.off);
  Stream<LoopMode> get loopModeStream => _loopMode.stream;
  LoopMode get loopMode => _loopMode.value;

  /// Индекс текущего трека в очереди (-1 если ничего не играет).
  final BehaviorSubject<int> _currentIndexSubject =
      BehaviorSubject<int>.seeded(-1);
  Stream<int> get currentIndexStream => _currentIndexSubject.stream;
  int get currentIndex => _currentIndex;

  // Поколение текущей загрузки. Старые завершаются молча.
  int _loadGeneration = 0;

  // Идёт ли сейчас загрузка нового трека (resolve URL + setAudioSource).
  // Пока true — пользовательский play() блокируется, чтобы не воскрешать старый.
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  PlayerService() {
    // Любая ошибка от ExoPlayer / локального прокси just_audio попадёт
    // сюда (например, обрыв сети при первичной загрузке трека). Без
    // onError эти ошибки становятся Unhandled Exception и роняют
    // изолят. Просто логируем — пользовательский интерфейс сам
    // отобразит "buffering" через playbackState.
    _player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object e, StackTrace st) {
        _log('playbackEventStream error: $e');
      },
    );
    _player.playerStateStream.listen(
      (state) {
        // Авто-переход на следующий трек только при штатном завершении.
        // На processingState=completed с position < duration это ошибка
        // (Source error), и skipToNext только усугубит ситуацию.
        if (state.processingState == ProcessingState.completed) {
          final pos = _player.position;
          final dur = _player.duration ?? Duration.zero;
          if (dur > Duration.zero && pos >= dur - const Duration(seconds: 1)) {
            skipToNext();
          }
        }
      },
      onError: (Object e, StackTrace st) {
        _log('playerStateStream error: $e');
      },
    );
  }

  // ===== Queue =====

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

  Future<void> _playIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;

    final myGen = ++_loadGeneration;
    _isLoading = true;
    _currentIndex = index;
    _currentIndexSubject.add(index);
    final track = _queue[index];
    _log('[$myGen] Playing index=$index track="${track.title}" id=${track.id}');

    mediaItem.add(_toMediaItem(track));

    // Мгновенно глушим звук — pause() возвращается сразу, а звук
    // обрывается синхронно. Без await, чтобы не блокировать переход.
    unawaited(_player.pause());
    unawaited(_player.seek(Duration.zero));

    try {
      final source = SourceRegistry.instance.require(track.sourceId);
      _log('[$myGen] Resolving audio source...');
      final sw = Stopwatch()..start();

      // Источник сам решает, как отдавать аудио. Для YouTube это
      // LockCachingAudioSource поверх локального файла — скачивает в
      // фоне и обслуживает seek-запросы из диска.
      final audioSource = await source.createAudioSource(track);

      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after resolve');
        return;
      }
      _log('[$myGen] AudioSource ready in ${sw.elapsedMilliseconds} ms');

      // Явно стопаем плеер перед загрузкой нового источника. Это
      // детерминированно освобождает предыдущий LockCachingAudioSource
      // (его прокси-сервер, HTTP-клиент, ExoPlayer внутренние буферы),
      // вместо того чтобы полагаться на lazy-cleanup в event loop'е.
      // На активном переключении треков это убирает накапливающиеся
      // микро-фризы UI после 3-5 нажатий «next».
      try {
        await _player.stop();
      } catch (_) {
        // best-effort; stop из idle состояния безопасен
      }

      await _player.setAudioSource(audioSource, preload: true);

      if (myGen != _loadGeneration) {
        _log('[$myGen] cancelled after setAudioSource');
        return;
      }

      _isLoading = false;
      _log('[$myGen] setAudioSource OK (${sw.elapsedMilliseconds} ms total),'
          ' starting playback');
      await _player.play();

      // Прогрев следующего трека — с задержкой, чтобы не конкурировать
      // за сеть/CPU с буферизацией текущего. К моменту реального
      // skipToNext этот prefetch уже отработает.
      _schedulePrefetchNext(myGen);
    } catch (e, st) {
      if (myGen != _loadGeneration) return;
      _isLoading = false;
      _log('[$myGen] PLAYBACK ERROR: $e');
      _log('Stack: $st');
    }
  }

  /// Отложенный таймер прогрева следующего трека.
  Timer? _prefetchTimer;

  /// Best-effort предзагрузка манифеста следующего трека. Запускается
  /// с задержкой [_prefetchDelay], чтобы не конкурировать с заливкой
  /// текущего трека в буфер ExoPlayer'а на первых секундах.
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
        } catch (_) {
          // молча
        }
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

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    // LockCachingAudioSource обслуживает любые позиции из локального
    // файла, поэтому seek работает в обе стороны мгновенно. Просто
    // оборачиваем в try/catch на случай редких ошибок прокси.
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

  /// Перемещает трек в очереди с позиции [oldIndex] на [newIndex].
  /// Корректирует [_currentIndex], чтобы текущий играющий трек не
  /// «потерялся». Не прерывает воспроизведение.
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;
    if (oldIndex == newIndex) return;

    final track = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, track);

    // Пересчёт индекса текущего трека.
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

  /// Разово перемешивает очередь. Текущий играющий трек остаётся на
  /// своём месте (становится первым), остальные тасуются. Это не режим —
  /// просто действие над очередью, поэтому никакого состояния не хранит.
  Future<void> shuffleQueue() async {
    if (_queue.length < 2) return;

    final current = _currentIndex >= 0 ? _queue[_currentIndex] : null;
    final rng = Random();
    // Fisher–Yates.
    for (var i = _queue.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = _queue[i];
      _queue[i] = _queue[j];
      _queue[j] = tmp;
    }
    // Возвращаем текущий трек в начало.
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

  /// Устанавливает режим повтора и пробрасывает его в just_audio.
  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode.add(mode);
    await _player.setLoopMode(mode);
  }

  /// Циклически переключает режим повтора: off → all → one → off.
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
