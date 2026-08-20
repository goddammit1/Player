// Тесты для новых страниц настроек: Appearance, Backup, About.
//
// Проверяются:
//   1. Рендер каждой страницы: заголовок виден, на корневом маршруте
//      кнопки «назад» нет (тот же canPop()-паттерн, что в SettingsPage).
//   2. Навигация: тап по плитке в SettingsPage пушит ОТДЕЛЬНУЮ страницу
//      (а не шторку), тап по chevron_left_rounded возвращает в настройки.
//
// Что подменяется:
//   - playerServiceProvider → _FakePlayer (NowPlayingOverlay слушает
//     mediaItem-поток плеера, поэтому нужен фейк, чтобы оверлей схлопнулся).
//   - PackageInfo.setMockInitialValues → AboutPage читает версию приложения.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/about_page.dart';
import 'package:player/ui/pages/appearance_page.dart';
import 'package:player/ui/pages/backup_page.dart';
import 'package:player/ui/pages/settings_page.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый плеер. Новые страницы не читают его напрямую, но
/// animatedPaletteProvider → currentPaletteProvider слушает mediaItem-поток
/// плеера, поэтому playerServiceProvider нужно подменить.
class _FakePlayer implements PlayerServiceInterface {
  @override
  bool get isLoading => false;

  @override
  int get currentIndex => 0;

  @override
  Stream<int> get currentIndexStream => BehaviorSubject.seeded(0).stream;

  @override
  double get boostDb => 0;

  @override
  Stream<double> get boostDbStream => BehaviorSubject.seeded(0.0).stream;

  @override
  void setBoost(double db) {}

  @override
  double get volume => 1.0;

  @override
  Stream<double> get volumeStream => BehaviorSubject.seeded(1.0).stream;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  LoopMode get loopMode => LoopMode.off;

  @override
  Stream<LoopMode> get loopModeStream =>
      BehaviorSubject.seeded(LoopMode.off).stream;

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<void> cycleLoopMode() async {}

  @override
  SleepTimerMode get sleepTimerMode => SleepTimerMode.off;

  @override
  Stream<SleepTimerMode> get sleepTimerModeStream =>
      BehaviorSubject.seeded(SleepTimerMode.off).stream;

  @override
  DateTime? get sleepTimerEndTime => null;

  @override
  Stream<DateTime?> get sleepTimerEndTimeStream =>
      BehaviorSubject<DateTime?>.seeded(null).stream;

  @override
  void startSleepTimer(Duration duration) {}

  @override
  Future<void> setStopAtEndOfSong() async {}

  @override
  void cancelSleepTimer() {}

  @override
  Stream<MediaItem?> get mediaItem =>
      BehaviorSubject<MediaItem?>.seeded(null).stream;

  @override
  MediaItem? get mediaItemValue => null;

  @override
  Stream<PlaybackState> get playbackState =>
      BehaviorSubject.seeded(PlaybackState()).stream;

  @override
  Stream<Duration> get positionStream =>
      BehaviorSubject.seeded(Duration.zero).stream;

  @override
  Stream<Duration?> get durationStream =>
      BehaviorSubject<Duration?>.seeded(null).stream;

  @override
  Stream<bool> get playingStream => BehaviorSubject.seeded(false).stream;

  @override
  AudioPlayer get rawPlayer =>
      throw UnimplementedError('not used in settings subpage tests');

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> skipToQueueItem(int index) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {}

  @override
  Future<void> playIndex(int index) async {}

  @override
  Future<void> addToQueue(Track track) async {}

  @override
  Future<void> insertToQueue(Track track) async {}

  @override
  Future<void> removeFromQueue(int index) async {}

  @override
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {}

  @override
  Future<void> shuffleQueue() async {}

  @override
  Future<void> updateCustomArtwork(String trackId, String newPath) async {}

  @override
  Future<void> resetCustomArtwork(String trackId) async {}

  @override
  Future<void> saveSession() async {}

  @override
  List<Track> get trackQueue => const [];
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Player',
      packageName: 'com.player.player',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
    await TestHarness.setUpDb();
  });

  tearDown(() async => await TestHarness.tearDownDb());

  Widget wrap(Widget home) {
    return ProviderScope(
      overrides: [playerServiceProvider.overrideWithValue(_FakePlayer())],
      child: MaterialApp(home: home),
    );
  }

  group('Subpages render as pages, not bottom sheets', () {
    testWidgets('AppearancePage renders its title', (tester) async {
      await tester.pumpWidget(wrap(const AppearancePage()));
      await tester.pumpAndSettle();

      expect(find.byType(AppearancePage), findsOneWidget);
      // Заголовок страницы в AppBar.
      expect(find.text('Appearance'), findsOneWidget);
      // Заголовок секции _Section рендерит через toUpperCase().
      expect(find.text('APPEARANCE'), findsOneWidget);
      // Раздел «Тема» и переключатель вибрации действительно на месте.
      expect(find.text('Theme'), findsOneWidget);
      // Заголовок секции «Haptics» рендерится как «HAPTICS» (toUpperCase).
      expect(find.text('HAPTICS'), findsOneWidget);
    });

    testWidgets('BackupPage renders its title and actions', (tester) async {
      await tester.pumpWidget(wrap(const BackupPage()));
      await tester.pumpAndSettle();

      expect(find.byType(BackupPage), findsOneWidget);
      expect(find.text('Backup'), findsOneWidget);
      expect(find.text('Export everything'), findsOneWidget);
      expect(find.text('Import everything'), findsOneWidget);
    });

    testWidgets('AboutPage renders title and version tile', (tester) async {
      await tester.pumpWidget(wrap(const AboutPage()));
      await tester.pumpAndSettle();

      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      // Плитка версии на месте (точный текст зависит от mock buildNumber,
      // поэтому проверяем только саму плитку).
      expect(find.text('Version'), findsOneWidget);
    });

    testWidgets(
        'subpages on root route have no back button (desktop section case)',
        (tester) async {
      await tester.pumpWidget(wrap(const AppearancePage()));
      await tester.pumpAndSettle();

      // Корневой маршрут: canPop() == false → кнопку «назад» прячем,
      // иначе тап по ней сломал бы Navigator (десктопный баг настроек).
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    });
  });

  group('SettingsPage pushes subpages via Navigator', () {
    Future<void> openTile(WidgetTester tester, String tileTitle) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsPage()),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Плитка раздела — кликабельный ListTile с заголовком tileTitle.
      await tester.tap(find.text(tileTitle));
      await tester.pumpAndSettle();
    }

    testWidgets('Appearance tile opens AppearancePage; back returns to settings',
        (tester) async {
      await openTile(tester, 'Appearance');

      // Заголовок «Appearance» — в AppBar страницы и в заголовке секции.
      // (Предыдущий маршрут может остаться в дереве для перехода, поэтому
      // строго по типу не проверяем.)
      expect(find.byType(AppearancePage), findsOneWidget);
      expect(find.text('Appearance'), findsWidgets);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('Backup tile opens BackupPage; back returns to settings',
        (tester) async {
      await openTile(tester, 'Backup');

      expect(find.byType(BackupPage), findsOneWidget);
      expect(find.text('Export everything'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('About tile opens AboutPage; back returns to settings',
        (tester) async {
      await openTile(tester, 'About');

      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('Version'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });
  });
}