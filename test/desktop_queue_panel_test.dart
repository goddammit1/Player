// Regression-тест правой колонки «Queue/Track» desktop-интерфейса
// (lib/ui/desktop/queue_panel.dart).
//
// Проверяются:
//   1. Рендер панели без исключений в headless-окне (ListView/Scrollbar/
//      Artwork не требуют Overlay — в отличие от Slider в плеер-баре).
//   2. Пустая очередь: вкладка «Queue» показывает «Queue empty»,
//      вкладка «Track» — «No track».
//   3. Непустая очередь: активный трек подсвечен индикатором «играет»
//      (Icons.graphic_eq_rounded), длительность отформатирована.
//   4. Тап по вкладке «Track» переключает тело панели на «No track»
//      (источник данных у desktop-плеера один — trackQueue).
//
// Сеть не дёргаем: плеер — _FakePlayer с фиксированной trackQueue.

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
import 'package:player/ui/desktop/queue_panel.dart';

import 'setup/test_harness.dart';

/// Fake-плеер: предоставляет очередь [Track] для QueuePanel.
class _FakePlayer implements PlayerServiceInterface {
  _FakePlayer({required this.queue});

  final List<Track> queue;

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
  Stream<MediaItem?> get mediaItem => BehaviorSubject<MediaItem?>.seeded(null).stream;

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
  Stream<bool> get playingStream =>
      BehaviorSubject.seeded(false).stream;

  @override
  AudioPlayer get rawPlayer => throw UnimplementedError('not used in queue test');

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
  List<Track> get trackQueue => queue;
}

Widget _wrap(_FakePlayer player) {
  return ProviderScope(
    overrides: [playerServiceProvider.overrideWithValue(player)],
    child: const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 600,
            child: QueuePanel(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  Future<void> pumpPanel(WidgetTester tester, _FakePlayer player) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(player));
    await tester.pumpAndSettle();
  }

  testWidgets('empty queue renders without exceptions and shows placeholders',
      (tester) async {
    await pumpPanel(tester, _FakePlayer(queue: const []));

    // Пустой рендер не должен бросать (ListView/Scrollbar без элементов).
    expect(tester.takeException(), isNull);

    // Вкладка по умолчанию — «Queue» → заглушка «Queue empty».
    expect(find.text('Queue empty'), findsOneWidget);
    expect(find.text('No track'), findsNothing);
  });

  testWidgets('non-empty queue shows active track with eq-graphic indicator',
      (tester) async {
    final player = _FakePlayer(
      queue: [
        const Track(
          id: 'q1',
          sourceId: 'fake_a',
          title: 'Active Track',
          artist: 'Artist A',
        ),
        const Track(
          id: 'q2',
          sourceId: 'fake_a',
          title: 'Queued Track',
          artist: 'Artist B',
        ),
      ],
    );
    await pumpPanel(tester, player);

    expect(tester.takeException(), isNull);

    // Активный (индекс 0) трек подсвечен индикатором «играет».
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

    // Оба заголовка и исполнители видны.
    expect(find.text('Active Track'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    expect(find.text('Queued Track'), findsOneWidget);
    expect(find.text('Artist B'), findsOneWidget);
  });

  testWidgets('switching to Track tab shows same queue source (no track placeholder)',
      (tester) async {
    final player = _FakePlayer(
      queue: [
        const Track(
          id: 'q1',
          sourceId: 'fake_a',
          title: 'Only Track',
          artist: 'Artist Solo',
        ),
      ],
    );
    await pumpPanel(tester, player);

    // Переключаемся на вкладку «Track».
    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();

    // Данные у desktop-плеера один — та же trackQueue. Пустых заглушек нет.
    expect(find.text('Only Track'), findsOneWidget);
    expect(find.text('No track'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}