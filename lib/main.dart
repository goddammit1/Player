import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/player_service.dart';
import 'core/playlist_repository.dart';
import 'core/providers.dart';
import 'sources/source_registry.dart';
import 'ui/pages/home_page.dart';

/// Палитра приложения. Pure-black темная тема, серые градации,
/// никакого «цветного» акцента — по дизайну, переданному заказчиком.
class AppColors {
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF161618);
  static const Color surfaceVariant = Color(0xFF212124);
  static const Color elevated = Color(0xFF212124);
  static const Color elevatedHi = Color(0xFF747474);
  static const Color surfaceProgressBar = Color(0x66747474);
  static const Color outline = Color(0xFF2F2F2F);
  // Весь текст в приложении — единый off-white #F9F8F8. Вторичный и
  // третичный различаются только прозрачностью того же цвета.
  static const Color textPrimary = Color(0xFFF9F8F8);
  static const Color textSecondary = Color(0xB3F9F8F8); // 70% alpha
  static const Color textTertiary = Color(0x80F9F8F8); // 50% alpha
}

Future<void> main() async {
  // Любая необработанная асинхронная ошибка (например, исключение из
  // потоков just_audio / dio при seek-е или обрыве сети) попадёт сюда
  // вместо того, чтобы убить Dart-изолят и обвалить весь плеер.
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Прозрачный системный bar — общий «гладкий» вид с тёмной темой.
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: AppColors.background,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );

      // Ошибки Flutter-фреймворка — туда же в лог, не в краш.
      FlutterError.onError = (details) {
        FlutterError.dumpErrorToConsole(details);
      };

      // Регистрируем источники треков (YouTube, Muzmo и т.д.).
      SourceRegistry.instance.registerDefaults();

      // Поднимаем хранилище плейлистов с диска до показа главного
      // экрана — иначе на старте мелькает пустая сетка.
      await PlaylistRepository.instance.ensureLoaded();

      // Запускаем audio_service — он создаст foreground-service на
      // Android, настроит уведомление и заберёт медиа-кнопки.
      final playerService = await AudioService.init<PlayerService>(
        builder: PlayerService.new,
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
    },
    (Object error, StackTrace stack) {
      // ignore: avoid_print
      debugPrint('[UncaughtZoneError] $error\n$stack');
    },
  );
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: 'Geist',
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        surface: AppColors.background,
        surfaceContainerHighest: AppColors.surface,
        primary: AppColors.textPrimary,
        onPrimary: Colors.black,
        secondary: AppColors.elevated,
        onSecondary: AppColors.textPrimary,
        outline: AppColors.outline,
      ),
    );

    return MaterialApp(
      title: 'Player',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.apply(
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
          fontFamily: 'Geist',
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.surface,
          modalBackgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          // Глобальный стиль для всех SnackBar'ов: тёмная карточка,
          // мягкий серый текст (а не пронзительно белый), короткое
          // дефолтное время показа.
          backgroundColor: AppColors.surfaceVariant,
          contentTextStyle: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          actionTextColor: AppColors.textPrimary,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        splashFactory: InkRipple.splashFactory,
      ),
      home: const HomePage(),
    );
  }
}
