// lib/core/platform/player_service_factory.dart
//
// Фабрика плеер-сервиса: инкапсулирует платформозависимый выбор между
// мобильным PlayerService (audio_service) и DesktopPlayerService.
// main.dart остаётся тонкой точкой входа и не знает, какой сервис
// создаётся — он получает готовый PlayerServiceInterface.
//
// Решение (Фаза 3): платформенное ветвление выносится из main.dart
// за фабрику, чтобы точку входа можно было тестировать и переиспользовать
// в DI-композиции.

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../player_service.dart';
import 'player_service_desktop.dart';
import '../player_service_interface.dart';

/// Платформо-зависимая фабрика плеер-сервисов.
///
/// На Android/iOS возвращает [PlayerService] через AudioService
/// (системные уведомления, lock-screen контролы, фоновая служба).
/// На остальных платформах (desktop: Windows/Linux/macOS) — чистый
/// [DesktopPlayerService] (just_audio без audio_service).
abstract final class PlayerServiceFactory {
  /// Возвращает `true` для мобильных платформ (Android/iOS).
  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Создаёт и инициализирует плеер-сервис для текущей платформы.
  static Future<PlayerServiceInterface> create() async {
    if (isMobile) {
      return AudioService.init<PlayerService>(
        builder: PlayerService.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.player.player.audio',
          androidNotificationChannelName: 'Player',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    }
    return DesktopPlayerService();
  }
}