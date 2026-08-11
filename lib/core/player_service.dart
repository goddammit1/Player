// lib/core/player_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' show ImageConfiguration, ImageStreamListener, Size;
import '../models/track.dart';
import '../sources/source_registry.dart';
import '../sources/artwork_provider.dart';
import 'app_database.dart';
import 'history_repository.dart';
import 'playlist_repository.dart';
import 'youtube_cache.dart';
import 'artwork_helper.dart';
import 'player_service_interface.dart';

// print -> adb logcat (tag: flutter)
// ignore: avoid_print
void _log(String msg) => print('[PlayerService] $msg');

enum SleepTimerMode { off, time, endOfTrack }

class PlayerService extends BaseAudioHandler with SeekHandler implements PlayerServiceInterface {
  static const String _boostDbKey = 'boost_db_v1';
  static const double maxBoostDb = kMaxBoostDb;

  @override
  MediaItem? get mediaItemValue => mediaItem.value;

  @override
  Future<void> removeFromQueue(int queueIndex) => removeQueueItemAt(queueIndex);

  @override
  Future<void> playIndex(int index) => _playIndex(index);

  @override
  List<Track> get trackQueue => _queue;

  final BehaviorSubject<double> _boostDb = BehaviorSubject<double>.seeded(0.0);
  @override
  Stream<double> get boostDbStream => _boostDb.stream;
  @override
  double get boostDb => _boostDb.value;

  late final AndroidLoudnessEnhancer _loudnessEnhancer;
  late final AudioPlayer _player;

  final List<Track> _queue = [];
  int _currentIndex = -1;

  final BehaviorSubject<LoopMode> _loopMode =
      BehaviorSubject<LoopMode>.seeded(LoopMode.off);
  @override
  Stream<LoopMode> get loopModeStream => _loopMode.stream;
  @override
  LoopMode get loopMode => _loopMode.value;

  final BehaviorSubject<int> _currentIndexSubject =
      BehaviorSubject<int>.seeded(-1);
  @override
  Stream<int> get currentIndexStream => _currentIndexSubject.stream;
  @override
  int get currentIndex => _currentIndex;

  int _loadGeneration = 0;
  bool _isLoading = false;
  @override
  bool get isLoading => _isLoading;

  Track? _pendingHistoryTrack;
  static const Duration _historyThreshold = Duration(seconds: 1);

  // ===== SLEEP TIMER =====
  final BehaviorSubject<SleepTimerMode> _sleepTimerMode =
      BehaviorSubject.seeded(SleepTimerMode.off);
  @override
  Stream<SleepTimerMode> get sleepTimerModeStream => _sleepTimerMode.stream;
  @override
  SleepTimerMode get sleepTimerMode => _sleepTimerMode.value;

  final BehaviorSubject<DateTime?> _sleepTimerEndTime =
      BehaviorSubject.seeded(null);
  @override
  Stream<DateTime?> get sleepTimerEndTimeStream => _sleepTimerEndTime.stream;
  @override
  DateTime? get sleepTimerEndTime => _sleepTimerEndTime.value;

  Timer? _sleepTimer;

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

          // Вызываем завершение трека без избыточных проверок позиции
          _onTrackFinished();
        }
      },
      onError: (Object e, StackTrace st) {
        _log('playerStateStream error: $e');
      },
    );

    _player.positionStream.listen(
      (pos) {
        final pending = _pendingHistoryTrack;
        if (pending == null) return;
        if (!_player.playing) return;
        if (pos < _historyThreshold) return;
        _pendingHistoryTrack = null;
        // Берём актуальную версию трека из очереди — к этому моменту
        // _fetchAndApplyArtwork мог уже обновить artworkUrl.
        final currentTrack = _currentIndex >= 0 && _currentIndex < _queue.length
            ? _queue[_currentIndex]
            : pending;
        unawaited(HistoryRepository.instance.add(currentTrack));
      },
      onError: (Object e, StackTrace st) {
        _log('positionStream error: $e');
      },
    );

    unawaited(_initBoost());
    unawaited(_restoreSession());
  }

  // Флаг защиты от повторных дублирующих событий завершения трека
  bool _isHandlingTrackFinish = false;

  // ===== SLEEP TIMER METHODS =====

  @override
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.time);
    _sleepTimerEndTime.add(DateTime.now().add(duration));

    _sleepTimer = Timer(duration, () async {
      _log('Sleep timer: Time expired! Waiting for current track to finish...');
      
      // Когда время истекло, переводим плеер в режим доигрывания текущего трека
      _sleepTimerMode.add(SleepTimerMode.endOfTrack);
      _sleepTimerEndTime.add(null);
      try {
        await _player.setLoopMode(LoopMode.off);
      } catch (_) {}
    });
  }

  @override
  Future<void> setStopAtEndOfSong() async {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.endOfTrack);
    _sleepTimerEndTime.add(null);

    try {
      await _player.setLoopMode(LoopMode.off);
    } catch (_) {}
  }

  @override
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimerMode.add(SleepTimerMode.off);
    _sleepTimerEndTime.add(null);

    // _player is always LoopMode.off — no need to restore
  }

  // ===== Авто-переход при завершении трека =====

  void _onTrackFinished() {
    // Если событие завершения уже обрабатывается — игнорируем дубли
    if (_isHandlingTrackFinish) return;
    _isHandlingTrackFinish = true;

    try {
      // 1. Проверяем таймер сна
      if (sleepTimerMode == SleepTimerMode.endOfTrack) {
        _log('Sleep timer: End of track reached, stopping playback like end of queue');
        cancelSleepTimer();
        // Плеер уже сам дошел до конца (completed). 
        // Мы просто НЕ вызываем _playIndex, чтобы очередь остановилась.
        return;
      }

      // 2. Стандартная логика авто-перехода
      switch (_loopMode.value) {
        case LoopMode.one:
          _log('LoopMode.one \u2192 replay index=$_currentIndex');
          _playIndex(_currentIndex);
          break;
        case LoopMode.all:
          final next = _currentIndex + 1;
          if (next < _queue.length) {
            _log('LoopMode.all \u2192 next index=$next');
            _playIndex(next);
          } else if (_queue.isNotEmpty) {
            _log('LoopMode.all \u2192 wrap to index=0');
            _playIndex(0);
          }
          break;
        case LoopMode.off:
          if (_currentIndex + 1 < _queue.length) {
            _log('LoopMode.off \u2192 next index=${_currentIndex + 1}');
            _playIndex(_currentIndex + 1);
          } else {
            _log('LoopMode.off \u2192 end of queue, stopping');
          }
          break;
      }
    } finally {
      // Игнорируем дублирующие эвенты плеера в течение 1 секунды
      Future.delayed(const Duration(milliseconds: 1000), () {
        _isHandlingTrackFinish = false;
      });
    }
  }

  // ===== BOOST METHODS =====

  Future<void> _initBoost() async {
    try {
      final savedStr = await AppDatabase.instance.getSetting(_boostDbKey);
      if (savedStr != null) {
        final saved = double.tryParse(savedStr) ?? 0.0;
        await setBoost(saved);
      }
    } catch (e) {
      _log('boost init failed: $e');
    }
  }

  @override
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
      await AppDatabase.instance.setSetting(_boostDbKey, db.toString());
    } catch (_) {}
  }

  Future<void> _reapplyBoost() async {
    try {
      await _loudnessEnhancer.setEnabled(true);
      await _loudnessEnhancer.setTargetGain(_boostDb.value);
    } catch (_) {}
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
    await _saveSession();
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
    await _saveSession();
  }

  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    queue.add(tracks.map(_toMediaItem).toList());
    if (tracks.isNotEmpty) {
      await _playIndex(startIndex);
      // _playIndex already saves session internally
    } else {
      await _saveSession();
    }
  }

  @override
  Future<void> addToQueue(Track track) async {
    _queue.add(track);
    queue.add([...queue.value, _toMediaItem(track)]);
    await _saveSession();
  }

  @override
  Future<void> insertToQueue(Track track) async {
    final insertIndex = _currentIndex >= 0 ? _currentIndex + 1 : 0;
    _queue.insert(insertIndex, track);

    if (insertIndex <= _currentIndex) {
      _currentIndex += 1;
      _currentIndexSubject.add(_currentIndex);
    }

    queue.add(_queue.map(_toMediaItem).toList());
    await _saveSession();
  }

  Future<void> _playIndex(int index, {bool isRetry = false}) async {
    if (index < 0 || index >= _queue.length) return;

    final myGen = ++_loadGeneration;
    _isLoading = true;
    _pendingHistoryTrack = null;
    _currentIndex = index;
    _currentIndexSubject.add(index);
    final track = _queue[index];
    _log('[$myGen] Playing index=$index track="${track.title}" '
        'id=${track.id} src=${track.sourceId}'
        '${isRetry ? ' (RETRY)' : ''}');

    mediaItem.add(_toMediaItem(track));
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
      _pendingHistoryTrack = track;
      _log('[$myGen] setAudioSource OK (${sw.elapsedMilliseconds} ms total),'
          ' starting playback');
      await _player.play();

      unawaited(_reapplyBoost());
      await _saveSession();
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

    // Если аудио-источник не загружен (например, после восстановления сессии),
    // загружаем текущий трек через _playIndex (который сам вызовет play())
    if (_player.processingState == ProcessingState.idle &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      _log('play() on idle player — loading current index=$_currentIndex');
      await _playIndex(_currentIndex);
      return;
    }

    await _player.play();
    await _saveSession();
  }

  void _warmArtwork(int index) {
    if (index >= 0 && index < _queue.length) {
      final track = _queue[index];
      final url = track.artworkUrl;
      if (url != null && url.isNotEmpty) {
        // Предзагружаем текущую обложку для быстрого отображения
        _precacheImage(url);
      }
      // Лениво проверяем, не устарела ли обложка (Genius/iTunes):
      // свежий URL возвращается из кэша мгновенно, устаревший (TTL истёк)
      // перезапрашивается — так подхватываются смены обложки в Genius.
      _fetchAndApplyArtwork(track, index);
    }
    final next = index + 1;
    if (next < _queue.length) {
      final nextTrack = _queue[next];
      final url = nextTrack.artworkUrl;
      if (url != null && url.isNotEmpty) {
        _precacheImage(url);
      }
      _fetchAndApplyArtwork(nextTrack, next);
    }
  }

  /// Лениво обновляет обложку трека в очереди через [ArtworkProvider].
  ///
  /// Сам провайдер решает, когда реально ходить в сеть: свежий URL (в
  /// пределах [ArtworkProvider.foundUrlTtl]) отдаётся из кэша без запросов,
  /// устаревший — перезапрашивается у Genius/iTunes. Это позволяет
  /// подхватывать смену обложки на стороне Genius при очередном
  /// проигрывании трека, не дёргая API на каждый трек.
  ///
  /// Если у трека уже есть «родная» обложка источника (SoundCloud
  /// `sndcdn.com`, YouTube `i.ytimg.com`, локальный файл) — не трогаем её:
  /// она стабильна, и перезапрос через Genius/iTunes может только заменить
  /// её на чужую картинку или ничего не дать.
  void _fetchAndApplyArtwork(Track track, int queueIndex) {
    final existing = track.artworkUrl;
    if (existing != null &&
        existing.isNotEmpty &&
        !ArtworkProvider.isProviderArtworkUrl(existing)) {
      return;
    }
    _fetchArtworkUrl(track).then((url) {
      if (url == null || url.isEmpty) return;
      if (queueIndex < 0 || queueIndex >= _queue.length) return;

      // Сравниваем с актуальной записью очереди: пока URL летел из сети,
      // обложка могла обновиться другим вызовом.
      final current = _queue[queueIndex];
      if (current.artworkUrl == url) return;

      // Обновляем трек в очереди
      final updated = current.copyWith(artworkUrl: url);
      _queue[queueIndex] = updated;

      // Обновляем mediaItem только для активного трека — иначе шторка
      // уведомлений может на секунду показать обложку следующего трека.
      if (queueIndex == _currentIndex) {
        mediaItem.add(_toMediaItem(updated));
      }
      // Обновляем queue stream — список обложек в UI должен быть актуален.
      queue.add(_queue.map(_toMediaItem).toList());
      // Пробрасываем обложку в плейлисты — чтобы она отображалась и сохранялась в БД
      unawaited(PlaylistRepository.instance.updateTrackArtwork(current.globalId, url));
      // И в историю прослушивания
      unawaited(HistoryRepository.instance.updateTrackArtwork(current.globalId, url));
    }).catchError((_) {});
  }

  /// Выбирает URL обложки для трека в очереди:
  /// 1. Если у трека нет обложки — пробуем восстановить «родную» из
  ///    источника (SoundCloud по ID и т.п.), т.к. Genius/iTunes её не знают.
  /// 2. Иначе — Genius/iTunes (с TTL-кэшем, устаревший URL перезапрашивается).
  Future<String?> _fetchArtworkUrl(Track track) async {
    final existing = track.artworkUrl;
    if (existing == null || existing.isEmpty) {
      try {
        final url = await SourceRegistry.instance
            .get(track.sourceId)
            ?.resolveArtwork(track);
        if (url != null && url.isNotEmpty) return url;
      } catch (_) {
        // Падение источника не мешает фолбэку на Genius/iTunes.
      }
    }
    return ArtworkProvider.instance
        .findArtwork(track.artist, track.title, preferredSize: 600);
  }

  void _precacheImage(String url) {
    unawaited(
      _precacheImageWithSize(url, 200).catchError((_) {}),
    );
  }

  Future<void> _precacheImageWithSize(String url, int size) async {
    final provider = CachedNetworkImageProvider(url);
    final config = ImageConfiguration(
      size: Size(size.toDouble(), size.toDouble()),
    );
    final stream = provider.resolve(config);
    final completer = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, _) {
        imageInfo.image.dispose();
        completer.complete();
      },
      onError: (exception, stackTrace) {
        completer.completeError(exception, stackTrace);
      },
    );
    stream.addListener(listener);
    try {
      await completer.future;
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    await _saveSession();
  }

  // ===== SESSION PERSISTENCE =====

  /// Сериализует [track] в Map, совместимый с `AppDatabase._trackFromRow`.
  static Map<String, dynamic> _trackToRow(Track track) {
    return {
      'track_id': track.id,
      'source_id': track.sourceId,
      'title': track.title,
      'artist': track.artist,
      'duration_ms': track.duration?.inMilliseconds,
      'artwork_url': track.artworkUrl,
      'quality_score': track.qualityScore,
      'quality_label': track.qualityLabel,
      'track_global_id': track.globalId,
      'extra_json': jsonEncode(AppDatabase.extraPrimitives(track.extra)),
    };
  }

  Future<void> _saveSession({int? positionMs}) async {
    try {
      final pos = positionMs ?? _player.position.inMilliseconds;
      final queueRows = _queue.map(_trackToRow).toList();
      await AppDatabase.instance.savePlaybackSession(
        queueRows: queueRows,
        currentIndex: _currentIndex,
        positionMs: pos,
      );
    } catch (_) {
      // Не даём ошибке БД уронить плеер.
    }
  }

  /// Публичный доступ для сохранения сессии из UI (например, при сворачивании).
  @override
  Future<void> saveSession() => _saveSession();

  Future<void> _restoreSession() async {
    try {
      final session = await AppDatabase.instance.loadPlaybackSession();
      if (session == null) return;

      _log('Restoring session: ${session.queue.length} tracks, '
          'index=${session.currentIndex}');

      _queue
        ..clear()
        ..addAll(session.queue);
      _currentIndex = session.currentIndex.clamp(-1, _queue.length - 1);
      _currentIndexSubject.add(_currentIndex);

      queue.add(_queue.map(_toMediaItem).toList());

      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        final track = _queue[_currentIndex];

        // Немедленно показываем трек в UI/шторке с сохранёнными метаданными,
        // не дожидаясь сетевого resolveStreamUrl.
        mediaItem.add(_toMediaItem(track));
        playbackState.add(PlaybackState(
          controls: [MediaControl.play],
          processingState: AudioProcessingState.ready,
          playing: false,
          queueIndex: _currentIndex,
        ));

        // Аудио-источник не загружаем — только показываем UI.
        // При нажатии Play сработает обычный _playIndex, который сам
        // сделает createAudioSource (с поддержкой кэша через LockCachingAudioSource).
      }
    } catch (e, st) {
      _log('Session restore failed: $e\n$st');
    }
  }

  // =============================================================

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    _log('onTaskRemoved — saving session');
    await _saveSession();
    // Не вызываем _player.stop()/_player.dispose() — на момент
    // onTaskRemoved главный изолят уже может быть мёртв, Platform
    // Channel для just_audio/sqflite недоступен, и dispose крашит
    // процесс до того как БД синкнется на диск.
    await super.onTaskRemoved();
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

  @override
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
    await _saveSession();
  }

  @override
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
    await _saveSession();
  }

  @override
  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode.add(mode);
    // always keep just_audio in LoopMode.off — we handle
    // one/all/off ourselves in _onTrackFinished
    await _player.setLoopMode(LoopMode.off);
  }

  @override
  Future<void> cycleLoopMode() {
    final next = switch (_loopMode.value) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    return setLoopMode(next);
  }

  // ===== Streams =====

  @override
  Stream<Duration> get positionStream => _player.positionStream;
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  Stream<bool> get playingStream => _player.playingStream;
  @override
  AudioPlayer get rawPlayer => _player;

  // ===== Helpers =====

  MediaItem _toMediaItem(Track t) {
    // Проверяем, есть ли сохранённая кастомная обложка для трека
    final customArt = ArtworkHelper.getCustomArtworkSync(t.id);
    final artUri = customArt != null
        ? Uri.file(customArt)
        : (t.artworkUrl != null ? Uri.parse(t.artworkUrl!) : null);

    return MediaItem(
      id: t.globalId,
      title: t.title,
      artist: t.artist,
      duration: t.duration,
      artUri: artUri,
      extras: {
        'sourceId': t.sourceId,
        'trackId': t.id,
        'originalArtworkUrl': t.artworkUrl,
      },
    );
  }

  /// Сбрасывает кастомную обложку трека на оригинальную (или пустую)
  @override
  Future<void> resetCustomArtwork(String trackId) async {
    // 1. Удаляем кастомную обложку с диска и из кэша
    await ArtworkHelper.removeCustomArtwork(trackId);

    // 2. Получаем оригинальный URL из текущего MediaItem (он сохраняется в extras)
    String? originalUrl;
    final current = mediaItem.value;
    if (current != null) {
      final currentTrackId = current.extras?['trackId'] as String? ?? current.id;
      if (currentTrackId == trackId) {
        originalUrl = current.extras?['originalArtworkUrl'] as String?;
      }
    }

    // 3. Обновляем трек в локальном списке очереди _queue — сбрасываем artworkUrl на оригинальный
    bool queueUpdated = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = _queue[i].copyWith(artworkUrl: originalUrl);
        queueUpdated = true;
      }
    }

    // 4. Если очередь изменилась — рассылаем обновленный список MediaItem
    if (queueUpdated) {
      queue.add(_queue.map(_toMediaItem).toList());
    }

    // 5. Обновляем активный проигрываемый MediaItem
    if (current != null) {
      final currentTrackId = current.extras?['trackId'] as String? ?? current.id;
      if (currentTrackId == trackId) {
        final updated = MediaItem(
          id: current.id,
          title: current.title,
          artist: current.artist,
          duration: current.duration,
          artUri: originalUrl != null ? Uri.tryParse(originalUrl) : null,
          extras: Map<String, dynamic>.from(current.extras ?? {}),
        );
        mediaItem.add(updated);
      }
    }

    // 6. Синхронизируем сброс с репозиториями (плейлисты, история), чтобы
    //    обложка в БД вернулась к оригинальной (как в updateCustomArtwork).
    String? globalId;
    for (final t in _queue) {
      if (t.id == trackId) {
        globalId = t.globalId;
        break;
      }
    }
    if (globalId != null && globalId.isNotEmpty && originalUrl != null) {
      unawaited(PlaylistRepository.instance.updateTrackArtwork(globalId, originalUrl));
      unawaited(
        HistoryRepository.instance.updateTrackArtwork(globalId, originalUrl),
      );
    }
  }

  /// Обновляет обложку трека (и в текущем проигрывателе, и во всей очереди)
  @override
  Future<void> updateCustomArtwork(String trackId, String newPath) async {
    final newArtUri = Uri.file(newPath);

    // 0. Находим globalId трека по trackId — по нему репозитории/БД знают трек.
    String? globalId;
    for (final t in _queue) {
      if (t.id == trackId) {
        globalId = t.globalId;
        break;
      }
    }

    // 1. Обновляем трек в локальном списке очереди _queue
    bool queueUpdated = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = _queue[i].copyWith(artworkUrl: newPath);
        queueUpdated = true;
      }
    }

    // 2. Если очередь изменилась — рассылаем обновленный список MediaItem
    if (queueUpdated) {
      queue.add(_queue.map(_toMediaItem).toList());
    }

    // 3. Обновляем активный проигрываемый MediaItem (шторку уведомлений и плеер)
    final current = mediaItem.value;
    if (current != null) {
      final currentTrackId = current.extras?['trackId'] as String? ?? current.id;
      if (currentTrackId == trackId) {
        final updated = MediaItem(
          id: current.id,
          title: current.title,
          artist: current.artist,
          duration: current.duration,
          artUri: newArtUri,
          extras: Map<String, dynamic>.from(current.extras ?? {}),
        );
        mediaItem.add(updated);
      }
    }

    // 4. Синхронизируем обложку с репозиториями (плейлисты, история), чтобы
    //    она сохранилась в БД и отражалась при экспорте бэкапа.
    if (globalId != null && globalId.isNotEmpty) {
      unawaited(PlaylistRepository.instance.updateTrackArtwork(globalId, newPath));
      unawaited(
        HistoryRepository.instance.updateTrackArtwork(globalId, newPath),
      );
    }
  }

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
