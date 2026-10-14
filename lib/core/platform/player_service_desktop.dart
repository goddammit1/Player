// lib/core/platform/player_service_desktop.dart
//
// Десктопный плеер-сервис (Windows): общее ядро очереди [QueueEngine]
// без audio_service на движке media_kit. Громкость сохраняется между
// запусками (слайдер в плеер-баре).

import '../playback/media_kit_backend.dart';
import '../playback/playback_backend.dart';
import '../playback/queue_engine.dart';

class DesktopPlayerService extends QueueEngine {
  DesktopPlayerService({
    PlaybackBackend? backend,
    super.environment,
  }) : super(
          backend: backend ?? MediaKitBackend(),
          persistVolume: true,
          logTag: 'DesktopPlayer',
        );
}
