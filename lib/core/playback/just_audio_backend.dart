// lib/core/playback/just_audio_backend.dart
//
// Мобильный бэкенд воспроизведения поверх just_audio (Android: ExoPlayer).
// [PlaybackSource] превращается ровно в те just_audio-объекты, которые
// раньше создавали сами источники, — поведение на Android не меняется.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../sources/playback_source.dart';
import '../../sources/soulseek_stream_audio_source.dart';
import 'playback_backend.dart';

void _log(String msg) => debugPrint('[JustAudioBackend] $msg');

/// just_audio-источник для [source]: офлайн-файл, поток с записью в кэш
/// ([LockCachingAudioSource]), HLS, растущий `.part` Soulseek.
AudioSource toJustAudioSource(PlaybackSource source, {String? tag}) {
  switch (source) {
    case LocalFile(:final path):
      return AudioSource.uri(Uri.file(path), tag: tag);
    case RemoteStream(:final uri, :final headers, :final cachePath):
      final h = headers.isEmpty ? null : headers;
      if (cachePath != null) {
        return LockCachingAudioSource(
          uri,
          headers: h,
          cacheFile: File(cachePath),
          tag: tag,
        );
      }
      return AudioSource.uri(uri, headers: h, tag: tag);
    case Hls(:final uri, :final headers):
      return AudioSource.uri(
        uri,
        headers: headers.isEmpty ? null : headers,
        tag: tag,
      );
    case GrowingFile(
        :final partPath,
        :final totalBytes,
        :final contentType,
        :final completion,
      ):
      return SoulseekStreamAudioSource(
        partPath: partPath,
        totalBytes: totalBytes,
        contentType: contentType,
        completion: completion,
        tag: tag,
      );
  }
}

class JustAudioBackend implements PlaybackBackend {
  JustAudioBackend._(this._player, this._loudnessEnhancer) {
    _subs.add(_player.playbackEventStream.listen(
      (_) => _changes.add(null),
      onError: (Object e, StackTrace st) => _log('playbackEventStream: $e'),
    ));
    _subs.add(_player.playerStateStream.listen(
      _onPlayerState,
      onError: (Object e, StackTrace st) => _log('playerStateStream: $e'),
    ));
  }

  /// Android: буферы ExoPlayer и LoudnessEnhancer для boost.
  factory JustAudioBackend.mobile() {
    final enhancer = AndroidLoudnessEnhancer();
    final player = AudioPlayer(
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 15),
          maxBufferDuration: Duration(seconds: 30),
          bufferForPlaybackDuration: Duration(milliseconds: 1500),
          bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 800),
        ),
      ),
      audioPipeline: AudioPipeline(androidAudioEffects: [enhancer]),
    );
    return JustAudioBackend._(player, enhancer);
  }


  final AudioPlayer _player;
  final AndroidLoudnessEnhancer? _loudnessEnhancer;
  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _completed =
      StreamController<void>.broadcast();
  ProcessingState _lastProcessingState = ProcessingState.idle;

  void _onPlayerState(PlayerState state) {
    _changes.add(null);
    final previous = _lastProcessingState;
    _lastProcessingState = state.processingState;
    if (state.processingState == ProcessingState.completed &&
        previous != ProcessingState.completed) {
      _completed.add(null);
    }
  }

  @override
  Stream<void> get stateChanges => _changes.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get positionStream => _player.positionStream;
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  bool get playing => _player.playing;
  @override
  AudioProcessingState get processingState =>
      switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
  @override
  Duration get position => _player.position;
  @override
  Duration get bufferedPosition => _player.bufferedPosition;
  @override
  double get speed => _player.speed;

  @override
  Future<void> load(PlaybackSource source, {String? tag}) async {
    await _player.setAudioSource(
      toJustAudioSource(source, tag: tag),
      preload: true,
    );
  }

  @override
  Future<void> play() async {
    // Future play() у just_audio завершается только при паузе/остановке/
    // конце трека — не ждём его.
    unawaited(_player.play().catchError((Object e) {
      _log('play() error: $e');
    }));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setBoost(double db) async {
    final enhancer = _loudnessEnhancer;
    if (enhancer == null) return;
    await enhancer.setEnabled(true);
    await enhancer.setTargetGain(db);
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _changes.close();
    await _completed.close();
    await _player.dispose();
  }
}
