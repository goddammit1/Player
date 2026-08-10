// Regression test: десктопный баг «Настройки → назад» → тёмный пустой экран.
//
// Симптом: в десктопной версии после тапа «Настройки» на левой панели и затем
// по кнопке «назад» в шапке страницы всё приложение «ломается» — остаётся
// только тёмный фон без единого элемента UI.
//
// Причина: SettingsPage — мобильная страница, которая на мобильных платформах
// всегда открывается через Navigator.push и поэтому имеет в AppBar кнопку
// «назад» (Navigator.pop). На десктопе страница встроена как раздел
// DesktopShell (IndexedStack) прямо в корневой маршрут приложения — pop
// корневого маршрута оставлял Navigator без единого маршрута, Overlay пустел
// и весь UI исчезал.
//
// Фикс: кнопка «назад» рендерится только когда Navigator.of(context).canPop()
// == true, т.е. когда страница реально открыта поверх другого маршрута.
// Этот тест проверяет оба сценария:
//   1. SettingsPage на корневом маршруте (аналог раздела десктопного shell) —
//      кнопки «назад» НЕТ.
//   2. SettingsPage, запушенная поверх другого маршрута (мобильный сценарий,
//      а также десктопные push из поиска/истории/плейлиста) — кнопка есть,
//      тап закрывает страницу и не ломает навигацию.

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
import 'package:player/ui/pages/settings_page.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый плеер. SettingsPage не читает его напрямую, но
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
      throw UnimplementedError('not used in settings test');

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

  testWidgets(
      'SettingsPage on the root route (desktop section) has no back button',
      (tester) async {
    await tester.pumpWidget(wrap(const SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    // Корневой маршрут: canPop() == false → кнопка «назад» не должна
    // отрисоваться, иначе тап по ней сломал бы Navigator.
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
  });

  testWidgets(
      'SettingsPage pushed over another route shows the back button '
      'and tapping it pops back without breaking navigation', (tester) async {
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

    // Пуш страницы настроек — как на мобильных платформах.
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    // Поверх другого маршрута canPop() == true → кнопка «назад» есть.
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

    // Тап по «назад» закрывает страницу и НЕ ломает навигацию.
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });
}
