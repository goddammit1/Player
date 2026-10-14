// lib/core/platform/windows_media_controls.dart
//
// Системные медиаконтролы Windows (SMTC): медиа-флайаут, экран блокировки и
// аппаратные медиаклавиши. Нативная часть — windows/runner/media_controls.cpp
// (C++/WinRT), связь — MethodChannel `player/media_controls`.
//
// Dart → Windows: метаданные трека (`update`), play/pause + позиция и
// длительность (`state`), сброс (`clear`).
// Windows → Dart: кнопки (`onButton`) и перемотка из флайаута (`onSeek`).

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import '../player_service_interface.dart';

void _log(String msg) => debugPrint('[MediaControls] $msg');

class WindowsMediaControls {
  WindowsMediaControls(
    this._player, {
    MethodChannel channel = const MethodChannel('player/media_controls'),
    this.resyncInterval = const Duration(seconds: 5),
  }) : _channel = channel;

  final PlayerServiceInterface _player;
  final MethodChannel _channel;

  /// Как часто досылать позицию во время воспроизведения, чтобы прогресс во
  /// флайауте не расходился с плеером.
  final Duration resyncInterval;

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _resync;
  bool _available = true;
  bool _hasItem = false;

  /// Длительность из метаданных трека: известна до загрузки источника
  /// (восстановленная сессия).
  int _itemDurationMs = 0;

  ({bool playing, int durationMs})? _lastState;
  int _lastPositionMs = 0;
  final Stopwatch _sinceState = Stopwatch();

  void attach() {
    _channel.setMethodCallHandler(_onNativeCall);
    _subs
      ..add(_player.mediaItem.listen(_onMediaItem))
      ..add(
        Rx.combineLatest3<
              PlaybackState,
              Duration?,
              Duration,
              ({bool playing, int durationMs, int positionMs})
            >(
              _player.playbackState,
              _player.durationStream.startWith(null),
              _player.positionStream.startWith(Duration.zero),
              (state, duration, position) => (
                playing: state.playing,
                durationMs: (duration ?? Duration.zero).inMilliseconds,
                positionMs: position.inMilliseconds,
              ),
            )
            .listen(_onState),
      );
  }

  Future<void> dispose() async {
    _resync?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _channel.setMethodCallHandler(null);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onButton':
        switch (call.arguments as String?) {
          case 'play':
            await _player.play();
          case 'pause':
            await _player.pause();
          case 'stop':
            await _player.pause();
          case 'next':
            await _player.skipToNext();
          case 'previous':
            await _player.skipToPrevious();
        }
      case 'onSeek':
        final ms = call.arguments as int?;
        if (ms != null) await _player.seek(Duration(milliseconds: ms));
    }
  }

  void _onMediaItem(MediaItem? item) {
    _hasItem = item != null;
    _itemDurationMs = item?.duration?.inMilliseconds ?? 0;
    if (item == null) {
      _lastState = null;
      unawaited(_invoke('clear'));
      return;
    }
    final art = item.artUri;
    unawaited(
      _invoke('update', {
        'title': item.title,
        'artist': item.artist ?? '',
        'album': item.album ?? '',
        'artwork': art == null
            ? ''
            : art.isScheme('file')
            ? art.toFilePath()
            : art.toString(),
      }),
    );
  }

  /// Шлёт состояние при смене play/pause или длительности, при скачке
  /// позиции (seek) и раз в [resyncInterval] во время воспроизведения.
  void _onState(({bool playing, int durationMs, int positionMs}) s) {
    // Без трека флайаут скрыт — состояние не шлём.
    if (!_hasItem) return;
    if (s.durationMs <= 0 && _itemDurationMs > 0) {
      s = (
        playing: s.playing,
        durationMs: _itemDurationMs,
        positionMs: s.positionMs,
      );
    }
    final last = _lastState;
    final expected =
        _lastPositionMs +
        (last != null && last.playing ? _sinceState.elapsedMilliseconds : 0);
    final changed =
        last == null ||
        last.playing != s.playing ||
        last.durationMs != s.durationMs ||
        (s.positionMs - expected).abs() > 1500 ||
        _sinceState.elapsed >= resyncInterval;
    if (!changed) return;
    _lastState = (playing: s.playing, durationMs: s.durationMs);
    _lastPositionMs = s.positionMs;
    _sinceState
      ..reset()
      ..start();
    unawaited(
      _invoke('state', {
        'playing': s.playing,
        'positionMs': s.positionMs,
        'durationMs': s.durationMs,
      }),
    );
  }

  Future<void> _invoke(String method, [Object? args]) async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'unavailable') _available = false;
      _log('$method: ${e.message}');
    } on MissingPluginException {
      // Не Windows-раннер (тесты, другие платформы).
      _available = false;
    }
  }
}
