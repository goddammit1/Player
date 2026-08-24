// Юнит-тест PlayerServiceFactory (lib/core/platform/player_service_factory.dart).
//
// Фабрика вынесена из main.dart в Фазе 3, чтобы платформенное ветвление
// (mobile PlayerService vs DesktopPlayerService) было изолированным.
// Здесь проверяем детерминированный предикат isMobile — без вызова create(),
// который требует инициализации audio_service (и не должен исполняться в
// обычном/headless прогоне). Тест не требует сети.
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/platform/player_service_factory.dart';

void main() {
  group('PlayerServiceFactory.isMobile', () {
    test('matches the platform predicate (kIsWeb/Platform flags)', () {
      // Тот же предикат, что в фабрике:
      //   if (kIsWeb) return false;
      //   return Platform.isAndroid || Platform.isIOS;
      final expected = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      expect(PlayerServiceFactory.isMobile, equals(expected));
    });

    test('is a bool (headless determinism)', () {
      expect(PlayerServiceFactory.isMobile, isA<bool>());
    });
  });
}