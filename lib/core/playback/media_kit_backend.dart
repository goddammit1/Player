// lib/core/playback/media_kit_backend.dart
//
// Десктопный бэкенд воспроизведения (Windows) поверх media_kit (libmpv).
//
// Локальные файлы и потоки без кэша mpv играет сам (заголовки — через
// `Media.httpHeaders`); стриминг с записью в кэш и растущие файлы Soulseek
// идут через локальный [StreamProxy].
//
// Boost: в сборках libmpv из media_kit (и audio, и video) ffmpeg урезан —
// нет `anull`, `alimiter`, компрессоров, `volume` не принимает параметры,
// так что `af=lavfi=[…]` не инициализируется; свойства `volume-gain` в
// mpv 0.36 ещё нет. Поэтому усиление — громкость mpv выше 100%: mpv
// переводит громкость в гейн кубически, (v/100)³, значит +N dB — это
// множитель 10^(N/60) к громкости пользователя. Лимитера нет: на громких
// мастерах при большом boost возможен клиппинг.

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rxdart/rxdart.dart';

import '../../sources/playback_source.dart';
import 'playback_backend.dart';
import 'stream_proxy.dart';

void _log(String msg) => debugPrint('[MediaKitBackend] $msg');

/// Источник не открылся: ошибка mpv или таймаут загрузки.
class MediaLoadException implements Exception {
  const MediaLoadException(this.message);
  final String message;

  @override
  String toString() => 'MediaLoadException: $message';
}

/// Громкость mpv (0..[mpvVolumeMax]) для громкости пользователя [volume]
/// (0..1) и усиления [boostDb]: гейн mpv = (v/100)³, поэтому +N dB —
/// множитель 10^(N/60).
@visibleForTesting
double mpvVolumeFor(double volume, double boostDb) =>
    (100 * volume.clamp(0.0, 1.0) * math.pow(10, boostDb / 60))
        .clamp(0.0, mpvVolumeMax)
        .toDouble();

/// Потолок громкости mpv: 100 · 10^(12/60) ≈ 158.5 — хватает на +12 dB.
const double mpvVolumeMax = 160;

class MediaKitBackend implements PlaybackBackend {
  MediaKitBackend({
    StreamProxy? proxy,
    this.loadTimeout = const Duration(seconds: 20),
  }) : _proxy = proxy ?? StreamProxy() {
    _player = Player(
      configuration: const PlayerConfiguration(title: 'Player'),
    );
    final native = _native;
    if (native != null) {
      // Растущий файл Soulseek у медленного пира может молчать дольше
      // дефолтных 5 с: прокси сам решает, когда загрузка зависла.
      unawaited(native.setProperty('network-timeout', '60'));
      unawaited(native.setProperty('volume-max', '$mpvVolumeMax'));
    }
    final s = _player.stream;
    _subs
      ..add(s.playing.listen((_) => _emit()))
      ..add(s.buffering.listen((_) => _emit()))
      ..add(s.buffer.listen((_) => _emit()))
      ..add(s.completed.listen(_onCompleted))
      ..add(s.error.listen((e) => _log('mpv error: $e')));
  }

  final StreamProxy _proxy;

  /// Сколько ждать, пока mpv откроет источник.
  final Duration loadTimeout;

  late final Player _player;
  final List<StreamSubscription<Object?>> _subs = [];
  final _changes = StreamController<void>.broadcast();
  final _completed = StreamController<void>.broadcast();

  bool _hasMedia = false;
  bool _loading = false;
  bool _lastCompleted = false;
  int _loadGeneration = 0;

  NativePlayer? get _native {
    final platform = _player.platform;
    return platform is NativePlayer ? platform : null;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _onCompleted(bool completed) {
    final previous = _lastCompleted;
    _lastCompleted = completed;
    _emit();
    if (completed && !previous && _hasMedia && !_loading) {
      _completed.add(null);
    }
  }

  @override
  Stream<void> get stateChanges => _changes.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration?> get durationStream => _player.stream.duration
      .map<Duration?>((d) => d > Duration.zero ? d : null)
      .startWith(_player.state.duration > Duration.zero
          ? _player.state.duration
          : null);
  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  bool get playing => _player.state.playing;

  @override
  AudioProcessingState get processingState {
    if (!_hasMedia) return AudioProcessingState.idle;
    if (_loading) return AudioProcessingState.loading;
    if (_player.state.completed) return AudioProcessingState.completed;
    if (_player.state.buffering) return AudioProcessingState.buffering;
    return AudioProcessingState.ready;
  }

  @override
  Duration get position => _player.state.position;
  @override
  Duration get bufferedPosition => _player.state.buffer;
  @override
  double get speed => _player.state.rate;

  Future<Media> _mediaFor(PlaybackSource source) async {
    switch (source) {
      case LocalFile(:final path):
        return Media(path);
      case RemoteStream(:final uri, :final headers, cachePath: null):
        return Media(uri.toString(), httpHeaders: headers);
      case Hls(:final uri, :final headers):
        return Media(uri.toString(), httpHeaders: headers);
      case RemoteStream() || GrowingFile():
        return Media((await _proxy.urlFor(source)).toString());
    }
  }

  @override
  Future<void> load(PlaybackSource source, {String? tag}) async {
    final gen = ++_loadGeneration;
    _hasMedia = true;
    _loading = true;
    _lastCompleted = false;
    _emit();
    final errors = <String>[];
    final errorSub = _player.stream.error.listen(errors.add);
    try {
      final media = await _mediaFor(source);
      if (gen != _loadGeneration) return;
      await _player.open(media, play: false);
      await _waitUntilOpened(gen, errors);
    } catch (_) {
      // Источник не открылся: бэкенд снова idle, чтобы следующий play()
      // ядра перезагрузил трек, а не «играл» пустой плеер.
      if (gen == _loadGeneration) {
        _hasMedia = false;
        try {
          await _player.stop();
        } catch (_) {}
      }
      rethrow;
    } finally {
      await errorSub.cancel();
      if (gen == _loadGeneration) {
        _loading = false;
        _emit();
      }
    }
  }

  /// Ждёт, пока mpv узнает длительность (источник открыт). Ошибка mpv или
  /// возврат ядра в idle после старта загрузки — источник не открылся.
  Future<void> _waitUntilOpened(int gen, List<String> errors) async {
    final native = _native;
    if (native == null) return;
    final sw = Stopwatch()..start();
    var seenActive = false;
    while (gen == _loadGeneration) {
      final duration = double.tryParse(await native.getProperty('duration'));
      if (duration != null && duration > 0) return;
      if (errors.isNotEmpty) throw MediaLoadException(errors.join('; '));
      final idle = await native.getProperty('idle-active');
      if (idle == 'no') seenActive = true;
      if (seenActive && idle == 'yes') {
        throw const MediaLoadException('mpv could not open the source');
      }
      if (sw.elapsed > loadTimeout) {
        throw MediaLoadException('timed out after ${loadTimeout.inSeconds} s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _loadGeneration++;
    _hasMedia = false;
    _loading = false;
    await _player.stop();
    _emit();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  double _volume = 1.0;
  double _boostDb = 0.0;

  @override
  Future<void> setVolume(double volume) {
    _volume = volume;
    return _applyVolume();
  }

  @override
  Future<void> setBoost(double db) {
    if (db == _boostDb) return Future.value();
    _boostDb = db;
    return _applyVolume();
  }

  Future<void> _applyVolume() =>
      _player.setVolume(mpvVolumeFor(_volume, _boostDb));

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _player.dispose();
    await _proxy.close();
    await _changes.close();
    await _completed.close();
  }
}
