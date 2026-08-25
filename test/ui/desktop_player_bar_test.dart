// Regression tests for the desktop player bar (Windows release issues).
//
// 1. When the stream duration is unknown (common on Windows for streams/HLS),
//    the slider must render disabled with a NEUTRAL track (not a full-width
//    "filled" bar) and honest '--:--' labels instead of '00:00 / 00:00'.
// 2. Layout must not overflow (any RenderFlex overflow fails the test).
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/desktop/desktop_player_bar.dart';

/// Минимальный фейковый плеер: переопределяем только потоки, которые
/// использует панель. Продолжительность задаётся через [duration].
class _FakePlayer implements PlayerServiceInterface {
  _FakePlayer({Duration? duration}) : _dur = BehaviorSubject.seeded(duration);

  final BehaviorSubject<Duration?> _dur;

  @override
  Stream<Duration?> get durationStream => _dur.stream;

  @override
  Stream<Duration> get positionStream =>
      BehaviorSubject.seeded(Duration.zero).stream;

  @override
  Stream<MediaItem?> get mediaItem => BehaviorSubject.seeded(
        const MediaItem(
          id: 'muzmo_1',
          title: 'эвтаназия',
          artist: 'Psychosis, Pavshiy',
        ),
      ).stream;

  @override
  MediaItem? get mediaItemValue =>
      const MediaItem(id: 'muzmo_1', title: 'эвтаназия', artist: 'Psychosis');

  @override
  Stream<PlaybackState> get playbackState =>
      BehaviorSubject.seeded(PlaybackState()).stream;

  @override
  Stream<bool> get playingStream =>
      BehaviorSubject.seeded(false).stream;

  @override
  Stream<LoopMode> get loopModeStream =>
      BehaviorSubject.seeded(LoopMode.off).stream;

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> cycleLoopMode() async {}

  @override
  bool get isLoading => false;

  @override
  int get currentIndex => 0;

  @override
  Stream<int> get currentIndexStream =>
      BehaviorSubject.seeded(0).stream;

  @override
  double get boostDb => 0;

  @override
  Stream<double> get boostDbStream => BehaviorSubject.seeded(0.0).stream;

  @override
  void setBoost(double db) {}

  @override
  double get volume => 1.0;

  @override
  Stream<double> get volumeStream =>
      BehaviorSubject.seeded(1.0).stream;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  LoopMode get loopMode => LoopMode.off;

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

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
  AudioPlayer get rawPlayer => throw UnimplementedError('not used in bar');

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

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

Widget _wrap(_FakePlayer player) {
  return ProviderScope(
    overrides: [playerServiceProvider.overrideWithValue(player)],
    child: const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 1280,
            height: DesktopPlayerBar.height,
            child: DesktopPlayerBar(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('unknown duration: neutral disabled slider, --:-- labels',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(_FakePlayer(duration: null)));
    await tester.pumpAndSettle();

    // Никаких исключений (в т.ч. overflow) — тест упадёт, если FlutterError
    // зарепортит проблему во время отрисовки панели.

    final slider = tester.widget<Slider>(find.byKey(const Key('seek_slider')));
    expect(slider.onChanged, isNull, reason: 'слайдер должен быть disabled');
    expect(slider.value, 0.0);

    // Честные метки времени вместо «00:00 / 00:00».
    expect(find.text('--:--'), findsNWidgets(2));
  });

  testWidgets('known duration: slider enabled, real labels', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dur = const Duration(minutes: 3, seconds: 34);
    await tester.pumpWidget(_wrap(_FakePlayer(duration: dur)));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byKey(const Key('seek_slider')));
    expect(slider.onChanged, isNotNull, reason: 'слайдер должен быть активен');
    expect(slider.max, closeTo(214000, 1));

    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('03:34'), findsOneWidget);
  });

  testWidgets('bar in MaterialApp.builder (above Overlay) does not throw',
      (tester) async {
    // Продакшн-раскладка: панель живёт в builder'е MaterialApp, т.е. ВЫШЕ
    // Navigator/Overlay. Tooltip без Overlay-предка кидал «No Overlay widget
    // found» при каждом построении панели (десятки раз в run_exe_log.txt).
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayer(duration: const Duration(seconds: 30));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerServiceProvider.overrideWithValue(player)],
        child: MaterialApp(
          builder: (context, child) => Material(
            // Как в исправленном _DesktopFrame (main.dart): Material + Overlay
            // обязательны, иначе Slider падает «No Material/No Overlay widget
            // found» и вместо трека рисуется серая плашка.
            color: const Color(0xFF000000),
            child: Column(
              children: [
                Expanded(child: child ?? const SizedBox.shrink()),
                SizedBox(
                  height: DesktopPlayerBar.height,
                  child: Overlay(
                    initialEntries: [
                      OverlayEntry(
                        builder: (_) => DesktopPlayerBar(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // До фикса падал здесь: «No Material widget found» и «No Overlay widget
    // found» (Slider), «No Overlay» (Tooltip) + overflow на 99929px.
    expect(tester.takeException(), isNull);
    expect(find.byType(IconButton), findsAtLeastNWidgets(4));
  });
}
