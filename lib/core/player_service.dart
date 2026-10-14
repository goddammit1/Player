// lib/core/player_service.dart
//
// Мобильный плеер-сервис (Android/iOS): audio_service-обёртка над общим
// ядром очереди [QueueEngine] с бэкендом just_audio. Ядро публикует
// mediaItem / playbackState / очередь — здесь они пробрасываются в
// субъекты audio_service (шторка уведомлений, lock screen, гарнитура).

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../models/track.dart';
import 'playback/just_audio_backend.dart';
import 'playback/queue_engine.dart';
import 'player_conversions.dart';
import 'player_service_interface.dart';

export 'player_service_interface.dart' show SleepTimerMode;

class PlayerService extends BaseAudioHandler
    with SeekHandler
    implements PlayerServiceInterface {
  static const double maxBoostDb = kMaxBoostDb;

  PlayerService() : this.withEngine(QueueEngine(backend: JustAudioBackend.mobile()));

  PlayerService.withEngine(this._engine) {
    _engine.mediaItem.listen(mediaItem.add);
    _engine.playbackState.listen(playbackState.add);
    _engine.trackQueueStream.listen(
      (tracks) => queue.add(tracks.map(PlayerConversions.toMediaItem).toList()),
    );
  }

  final QueueEngine _engine;

  // ===== Состояние =====

  @override
  bool get isLoading => _engine.isLoading;
  @override
  int get currentIndex => _engine.currentIndex;
  @override
  Stream<int> get currentIndexStream => _engine.currentIndexStream;
  @override
  List<Track> get trackQueue => _engine.trackQueue;
  @override
  Stream<List<Track>> get trackQueueStream => _engine.trackQueueStream;
  @override
  MediaItem? get mediaItemValue => _engine.mediaItemValue;

  @override
  double get boostDb => _engine.boostDb;
  @override
  Stream<double> get boostDbStream => _engine.boostDbStream;
  @override
  void setBoost(double db) => _engine.setBoost(db);

  @override
  double get volume => _engine.volume;
  @override
  Stream<double> get volumeStream => _engine.volumeStream;
  @override
  Future<void> setVolume(double volume) => _engine.setVolume(volume);

  @override
  LoopMode get loopMode => _engine.loopMode;
  @override
  Stream<LoopMode> get loopModeStream => _engine.loopModeStream;
  @override
  Future<void> setLoopMode(LoopMode mode) => _engine.setLoopMode(mode);
  @override
  Future<void> cycleLoopMode() => _engine.cycleLoopMode();

  @override
  SleepTimerMode get sleepTimerMode => _engine.sleepTimerMode;
  @override
  Stream<SleepTimerMode> get sleepTimerModeStream =>
      _engine.sleepTimerModeStream;
  @override
  DateTime? get sleepTimerEndTime => _engine.sleepTimerEndTime;
  @override
  Stream<DateTime?> get sleepTimerEndTimeStream =>
      _engine.sleepTimerEndTimeStream;
  @override
  void startSleepTimer(Duration duration) => _engine.startSleepTimer(duration);
  @override
  Future<void> setStopAtEndOfSong() => _engine.setStopAtEndOfSong();
  @override
  void cancelSleepTimer() => _engine.cancelSleepTimer();

  @override
  Stream<Duration> get positionStream => _engine.positionStream;
  @override
  Stream<Duration?> get durationStream => _engine.durationStream;
  @override
  Stream<bool> get playingStream => _engine.playingStream;

  // ===== audio_service controls =====

  @override
  Future<void> play() => _engine.play();
  @override
  Future<void> pause() => _engine.pause();
  @override
  Future<void> seek(Duration position) => _engine.seek(position);
  @override
  Future<void> skipToNext() => _engine.skipToNext();
  @override
  Future<void> skipToPrevious() => _engine.skipToPrevious();
  @override
  Future<void> skipToQueueItem(int index) => _engine.skipToQueueItem(index);

  @override
  Future<void> stop() async {
    await _engine.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Немедленный flush: процесс может быть убит сразу после onTaskRemoved.
    // Плеер не останавливаем и не освобождаем — на этот момент основной
    // изолят уже может быть мёртв, и dispose крашит процесс до того, как
    // БД синкнется на диск.
    await _engine.saveSession();
    await super.onTaskRemoved();
  }

  // ===== Очередь =====

  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) =>
      _engine.setQueue(tracks, startIndex: startIndex);
  @override
  Future<void> playIndex(int index) => _engine.playIndex(index);
  @override
  Future<void> addToQueue(Track track) => _engine.addToQueue(track);
  @override
  Future<void> insertToQueue(Track track) => _engine.insertToQueue(track);
  @override
  Future<void> removeFromQueue(int index) => _engine.removeFromQueue(index);
  @override
  Future<void> removeQueueItemAt(int index) => _engine.removeFromQueue(index);
  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index =
        _engine.trackQueue.indexWhere((t) => t.globalId == mediaItem.id);
    if (index >= 0) await _engine.removeFromQueue(index);
  }

  @override
  Future<void> reorderQueueItem(int oldIndex, int newIndex) =>
      _engine.reorderQueueItem(oldIndex, newIndex);
  @override
  Future<void> shuffleQueue() => _engine.shuffleQueue();
  @override
  Future<void> clearQueue() => _engine.clearQueue();

  // ===== Обложки / сессия =====

  @override
  Future<void> updateCustomArtwork(String trackId, String newPath) =>
      _engine.updateCustomArtwork(trackId, newPath);
  @override
  Future<void> resetCustomArtwork(String trackId) =>
      _engine.resetCustomArtwork(trackId);

  @override
  Future<void> saveSession() => _engine.saveSession();
}
