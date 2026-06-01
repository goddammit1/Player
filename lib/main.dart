import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/player_service.dart';
import 'core/providers.dart';
import 'sources/source_registry.dart';
import 'ui/pages/search_page.dart';

Future<void> main() async {
  // Любая необработанная асинхронная ошибка (например, исключение из
  // потоков just_audio / dio при seek-е или обрыве сети) попадёт сюда
  // вместо того, чтобы убить Dart-изолят и обвалить весь плеер.
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Ошибки Flutter-фреймворка — туда же в лог, не в краш.
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details);
    };

    // Регистрируем источники треков (YouTube и т.д.)
    SourceRegistry.instance.registerDefaults();

    // Запускаем audio_service — он создаст foreground-service на Android,
    // настроит уведомление и заберёт медиа-кнопки.
    final playerService = await AudioService.init<PlayerService>(
      builder: () => PlayerService(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.player.player.audio',
        androidNotificationChannelName: 'Player',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );

    runApp(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(playerService),
        ],
        child: const PlayerApp(),
      ),
    );
  }, (Object error, StackTrace stack) {
    // ignore: avoid_print
    debugPrint('[UncaughtZoneError] $error\n$stack');
  });
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SearchPage(),
    );
  }
}
