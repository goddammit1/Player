// Фейки для юнит-тестов ядра очереди: бэкенд воспроизведения без звука
// и окружение без БД / сети / источников.

import 'dart:async';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:player/core/playback/playback_backend.dart';
import 'package:player/core/playback/queue_environment.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/playback_source.dart';

class FakeBackend implements PlaybackBackend {
  final calls = <String>[];
  final loaded = <PlaybackSource>[];

  /// Ошибка следующей загрузки (сбрасывается после броска).
  Object? loadError;

  final _changes = StreamController<void>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _playingCtl = StreamController<bool>.broadcast(sync: true);

  @override
  bool playing = false;
  @override
  AudioProcessingState processingState = AudioProcessingState.idle;
  @override
  Duration position = Duration.zero;

  void finishTrack() {
    processingState = AudioProcessingState.completed;
    playing = false;
    _changes.add(null);
    _completed.add(null);
  }

  void emitPosition(Duration p) {
    position = p;
    _position.add(p);
  }

  @override
  Stream<void> get stateChanges => _changes.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => _playingCtl.stream;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  double get speed => 1.0;

  @override
  Future<void> load(PlaybackSource source, {String? tag}) async {
    calls.add('load:$tag');
    final error = loadError;
    if (error != null) {
      loadError = null;
      throw error;
    }
    loaded.add(source);
    processingState = AudioProcessingState.ready;
    position = Duration.zero;
    _changes.add(null);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    playing = false;
    processingState = AudioProcessingState.idle;
  }

  @override
  Future<void> seek(Duration p) async {
    calls.add('seek:${p.inSeconds}');
    position = p;
  }

  double? volume;
  double? boost;

  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> setBoost(double db) async => boost = db;

  @override
  Future<void> dispose() async {
    await _changes.close();
    await _completed.close();
    await _position.close();
    await _playingCtl.close();
  }
}

class FakeEnvironment implements QueueEnvironment {
  final resolved = <String>[];
  final evicted = <String>[];
  final history = <Track>[];
  final settings = <String, String>{};
  final persistedArtwork = <String, String>{};
  final saved = <SavedSession>[];
  SavedSession? session;

  /// Ошибки resolve по id трека (бросаются при каждом вызове).
  final failingIds = <String>{};

  /// Ручное завершение resolve по id трека.
  final gates = <String, Completer<void>>{};

  /// Ответ провайдера обложек по id трека.
  final artwork = <String, String>{};

  @override
  Future<PlaybackSource> resolve(Track track) async {
    resolved.add(track.id);
    final gate = gates[track.id];
    if (gate != null) await gate.future;
    if (failingIds.contains(track.id)) throw StateError('no ${track.id}');
    return LocalFile('/music/${track.id}.mp3');
  }

  /// Сколько раз ядро отказывалось от начатых resolve.
  int cancelPendingResolvesCalls = 0;

  @override
  void cancelPendingResolves() => cancelPendingResolvesCalls++;

  @override
  Future<void> prefetch(Track track) async {}
  @override
  Future<void> evictCache(Track track) async => evicted.add(track.id);

  /// Какие ошибки воспроизведения повторять (по умолчанию — все).
  bool Function(Object error) retryable = (_) => true;
  @override
  bool isRetryable(Object error) => retryable(error);
  @override
  void protectCache(Track track) {}
  @override
  bool needsArtworkRefresh(Track track) => artwork.containsKey(track.id);
  @override
  Future<String?> fetchArtworkUrl(Track track) async => artwork[track.id];
  @override
  void precacheArtwork(String url) {}
  @override
  void persistArtwork(String globalId, String url) =>
      persistedArtwork[globalId] = url;
  @override
  Future<void> removeCustomArtwork(String trackId) async {}
  @override
  Future<void> addToHistory(Track track) async => history.add(track);
  @override
  Future<String?> getSetting(String key) async => settings[key];
  @override
  Future<void> setSetting(String key, String value) async =>
      settings[key] = value;
  @override
  Future<SavedSession?> loadSession() async => session;
  @override
  Future<void> saveSession({
    required List<Track> queue,
    required int currentIndex,
    required int positionMs,
  }) async {
    saved.add((
      queue: queue,
      currentIndex: currentIndex,
      positionMs: positionMs,
    ));
  }
}

Track track(String id) => Track(
      id: id,
      sourceId: 'fake',
      title: 'Title $id',
      artist: 'Artist',
    );
