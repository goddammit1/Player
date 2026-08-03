import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_database.dart';
import 'core/haptic_helper.dart';
import 'core/history_repository.dart';
import 'core/player_service.dart';
import 'core/playlist_backup.dart';
import 'core/playlist_repository.dart';
import 'core/providers.dart';
import 'sources/source_registry.dart';
import 'ui/pages/home_page.dart';
import 'core/youtube_cache.dart';
import 'core/artwork_helper.dart';


/// Палитра приложения. Pure-black темная тема, серые градации,
/// никакого «цветного» акцента — по дизайну, переданному заказчиком.



Future<void> main() async {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      await ArtworkHelper.init();

      // === ЗАГРУЗКА ЛИМИТОВ КЭША ===
      await YoutubeCache.loadLimits();
      // ===============================

      // === ИНИЦИАЛИЗАЦИЯ HAPTIC FEEDBACK ===
      await HapticHelper.initialize();
      // =====================================

      // === НАСТРОЙКА RAM-КЭША ОБЛОЖЕК ===
      // По умолчанию Flutter ImageCache держит 1000 картинок / 100 МБ.
      // При длинной очереди и больших обложках это приводит к вытеснению
      // даже недавно показанных артов. Привязываем лимит к дисковому
      // лимиту обложек: RAM = ~25% от дискового, но не более 128 МБ.
      final imageCache = PaintingBinding.instance.imageCache;
      final maxArtworkBytes = YoutubeCache.maxArtworkCacheMB * 1024 * 1024;
      final maxRamBytes = (maxArtworkBytes / 4).clamp(0, 128 * 1024 * 1024);
      imageCache.maximumSize = 1500;
      imageCache.maximumSizeBytes = maxRamBytes.toInt();
      // ==================================

      // === МИГРАЦИЯ SharedPreferences → SQLite ===
      await _migrateToSqliteIfNeeded();
      // ===========================================

      // === ИНИЦИАЛИЗАЦИЯ РЕПОЗИТОРИЕВ (SQLite) ===
      // PlaylistRepository и HistoryRepository теперь читают из БД.
      await PlaylistRepository.instance.ensureLoaded();
      await HistoryRepository.instance.ensureLoaded();
      // ===========================================

      // === АВТО-ВОССТАНОВЛЕНИЕ ИЗ ПОЛНОГО БЭКАПА ===
      // Если БД пуста (первый запуск после переустановки), ищем
      // player_full_backup_*.json в документах приложения и предлагаем
      // восстановить все данные одним нажатием.
      await _autoRestoreBackupIfNeeded();
      // =============================================

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

/// Мигрирует данные из SharedPreferences в SQLite при первом запуске
/// после обновления. Идемпотентна.
///
/// Версия v1 ошибочно использовала ключи `playlists_json_v1` /
/// `listen_history_json_v1` вместо реальных `playlists_v1` / `listen_history_v1`,
/// из-за чего плейлисты и история не перенеслись.
/// Версия v2 исправляет ключи и разрешает повторную миграцию.
Future<void> _migrateToSqliteIfNeeded() async {
  final sp = await SharedPreferences.getInstance();

  // Читаем старые данные из SharedPreferences
  // v2: правильные ключи (`playlists_v1` / `listen_history_v1`),
  //     а не ошибочные `playlists_json_v1` / `listen_history_json_v1`.
  final playlistsJson = sp.getString('playlists_v1') ?? '';
  final listenHistoryJson = sp.getString('listen_history_v1') ?? '';
  final historyLimit = sp.getInt('history_limit_v1') ?? 100;
  final searchHistory = sp.getStringList('search_history_v1') ?? <String>[];

  // Собираем все настройки, исключая внутренние ключи flutter.*
  final allSettings = <String, String>{};
  for (final key in sp.getKeys()) {
    if (key.startsWith('flutter.')) continue;
    final value = sp.get(key);
    if (value != null) {
      allSettings[key] = value.toString();
    }
  }

  final migrated = await AppDatabase.instance.migrateFromSharedPreferences(
    playlistsJson: playlistsJson,
    listenHistoryJson: listenHistoryJson,
    historyLimit: historyLimit,
    searchHistory: searchHistory,
    allSettings: allSettings,
  );

  if (migrated) {
    debugPrint('[Migration] SharedPreferences → SQLite done.');
  }
}

/// При первом запуске после переустановки (или чистой установки)
/// проверяет, есть ли в каталоге документов приложения файлы
/// `player_full_backup_*.json`. Если БД пуста и файл найден — предлагает
/// восстановить все данные из бэкапа одним нажатием.
///
/// Это срабатывает:
/// - После ручного экспорта/импорта через share-sheet
/// - После авто-бэкапа Android (если копия попала в Documents/)
/// - Когда пользователь вручную положил файл бэкапа в папку приложения
///
/// Функция вызывается до инициализации UI, поэтому показывает диалог
/// средствами платформы (AlertDialog без контекста Flutter).
Future<void> _autoRestoreBackupIfNeeded() async {
  // Только если БД пуста
  final isEmpty = await AppDatabase.instance.isEmptyForImport();
  if (!isEmpty) return;

  try {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final name = f.uri.pathSegments.lastOrNull ?? '';
          return name.startsWith('player_full_backup_') &&
              name.endsWith('.json');
        })
        .toList();

    if (files.isEmpty) return;

    // Сортируем по дате изменения (новый сверху) и берём последний
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final best = files.first;
    debugPrint('[AutoRestore] Found backup: ${best.path}');

    // Импортируем молча — это автоматическое восстановление
    await FullBackup.importFromFile(best.path);
    debugPrint('[AutoRestore] Restored from ${best.path}');
  } catch (e) {
    debugPrint('[AutoRestore] Failed: $e');
    // Не блокируем запуск приложения при ошибке восстановления
  }
}

class _SessionAutoSave extends StatefulWidget {
  final Widget child;
  const _SessionAutoSave({required this.child});

  @override
  State<_SessionAutoSave> createState() => _SessionAutoSaveState();
}

class _SessionAutoSaveState extends State<_SessionAutoSave>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // При сворачивании / входящем звонке / закрытии приложения
      // сохраняем сессию плеера. Это надёжнее, чем полагаться только
      // на onTaskRemoved(), который может не сработать до первого
      // взаимодействия с MediaSession.
      try {
        ProviderScope.containerOf(context)
            .read(playerServiceProvider)
            .saveSession();
      } catch (_) {
        // Провайдер может быть не готов — игнорируем.
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PlayerApp extends ConsumerWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    // Навбар Android следует за фоном динамической темы.
    // setSystemUIOverlayStyle применяет стиль максимум раз за кадр — дёшево
    // даже при пересборке во время анимации палитры.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: colors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

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
      home: const _SessionAutoSave(child: HomePage()),
    );
  }
}