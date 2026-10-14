// lib/core/playback/playback_backend.dart
//
// Абстракция «бэкенда воспроизведения» под общим ядром очереди
// ([QueueEngine]): только загрузка одного источника и транспорт.
// Очередь, повторы, история, сессия и обложки живут в ядре и одинаковы
// для мобильного (just_audio) и десктопного (media_kit) движков.

import 'package:audio_service/audio_service.dart' show AudioProcessingState;

import '../../sources/playback_source.dart';

abstract class PlaybackBackend {
  /// Любое изменение playing / processingState / буфера: ядро публикует
  /// новый `PlaybackState`.
  Stream<void> get stateChanges;

  /// Трек доигран до конца. Событие приходит один раз на переход в
  /// «завершено», а не на каждое обновление состояния.
  Stream<void> get completed;

  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;

  bool get playing;
  AudioProcessingState get processingState;
  Duration get position;
  Duration get bufferedPosition;
  double get speed;

  /// Загружает источник и готовит его к воспроизведению (без старта).
  /// [tag] — идентификатор трека для логов и движков, которые его хранят.
  Future<void> load(PlaybackSource source, {String? tag});

  /// Запускает воспроизведение. Завершается, когда команда принята, — не
  /// ждёт конца трека или паузы.
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Громкость пользователя, 0.0..1.0.
  Future<void> setVolume(double volume);

  /// Усиление громкости в dB (0..[kMaxBoostDb]), отдельно от громкости.
  Future<void> setBoost(double db);

  Future<void> dispose();
}
