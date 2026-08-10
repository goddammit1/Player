import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/track.dart';
import 'player_service.dart' show SleepTimerMode;

abstract class PlayerServiceInterface {
  bool get isLoading;
  int get currentIndex;
  Stream<int> get currentIndexStream;

  double get boostDb;
  Stream<double> get boostDbStream;
  void setBoost(double db);

  LoopMode get loopMode;
  Stream<LoopMode> get loopModeStream;
  Future<void> setLoopMode(LoopMode mode);
  Future<void> cycleLoopMode();

  SleepTimerMode get sleepTimerMode;
  Stream<SleepTimerMode> get sleepTimerModeStream;
  DateTime? get sleepTimerEndTime;
  Stream<DateTime?> get sleepTimerEndTimeStream;
  void startSleepTimer(Duration duration);
  Future<void> setStopAtEndOfSong();
  void cancelSleepTimer();

  Stream<MediaItem?> get mediaItem;
  MediaItem? get mediaItemValue;
  Stream<PlaybackState> get playbackState;

  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;
  AudioPlayer get rawPlayer;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> skipToQueueItem(int index);
  Future<void> stop();

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0});
  Future<void> playIndex(int index);
  Future<void> addToQueue(Track track);
  Future<void> insertToQueue(Track track);
  Future<void> removeFromQueue(int index);
  Future<void> reorderQueueItem(int oldIndex, int newIndex);
  Future<void> shuffleQueue();

  Future<void> updateCustomArtwork(String trackId, String newPath);
  Future<void> resetCustomArtwork(String trackId);

  Future<void> saveSession();

  List<Track> get trackQueue;
}

const double kMaxBoostDb = 12.0;