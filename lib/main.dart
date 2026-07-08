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
import 'core/youtube_cache.dart';


/// Палитра приложения. Pure-black темная тема, серые градации,
/// никакого «цветного» акцента — по дизайну, переданному заказчиком.



Future<void> main() async {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // === ЗАГРУЗКА ЛИМИТОВ КЭША ===
      await YoutubeCache.loadLimits();
      // ===============================

      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Color(0xFF000000),
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );

      FlutterError.onError = (details) {
        FlutterError.dumpErrorToConsole(details);
      };

      SourceRegistry.instance.registerDefaults();

      await PlaylistRepository.instance.ensureLoaded();

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
      debugPrint('[UncaughtZoneError] $error\n$stack');
    },
  );
}

class PlayerApp extends ConsumerWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ИСПОЛЬЗУЕМ animatedPaletteProvider ВМЕСТО currentPaletteProvider
    final colors = ref.watch(animatedPaletteProvider);

    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: 'Geist',
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      colorScheme: ColorScheme.dark(
        surface: colors.background,
        surfaceContainerHighest: colors.elevated,
        primary: colors.textPrimary,
        onPrimary: Colors.black,
        secondary: colors.elevated,
        onSecondary: colors.textPrimary,
        outline: colors.outline,
      ),
    );

    return MaterialApp(
      title: 'Player',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.apply(
          bodyColor: colors.textPrimary,
          displayColor: colors.textPrimary,
          fontFamily: 'Geist',
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: colors.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          iconTheme: IconThemeData(color: colors.textPrimary),
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: colors.elevated,
          modalBackgroundColor: colors.elevated,
          surfaceTintColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: colors.elevatedVariant,
          contentTextStyle: TextStyle(
            color: colors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          actionTextColor: colors.textPrimary,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        splashFactory: InkRipple.splashFactory,
      ),
      home: const HomePage(),
    );
  }
}