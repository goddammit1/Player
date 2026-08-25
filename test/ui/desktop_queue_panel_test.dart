// Regression-С‚РµСЃС‚ РїСЂР°РІРѕР№ РєРѕР»РѕРЅРєРё В«Queue/TrackВ» desktop-РёРЅС‚РµСЂС„РµР№СЃР°
// (lib/ui/desktop/queue_panel.dart).
//
// РџСЂРѕРІРµСЂСЏСЋС‚СЃСЏ:
//   1. Р РµРЅРґРµСЂ РїР°РЅРµР»Рё Р±РµР· РёСЃРєР»СЋС‡РµРЅРёР№ РІ headless-РѕРєРЅРµ (ListView/Scrollbar/
//      Artwork РЅРµ С‚СЂРµР±СѓСЋС‚ Overlay вЂ” РІ РѕС‚Р»РёС‡РёРµ РѕС‚ Slider РІ РїР»РµРµСЂ-Р±Р°СЂРµ).
//   2. РџСѓСЃС‚Р°СЏ РѕС‡РµСЂРµРґСЊ: РІРєР»Р°РґРєР° В«QueueВ» РїРѕРєР°Р·С‹РІР°РµС‚ В«Queue emptyВ»,
//      РІРєР»Р°РґРєР° В«TrackВ» вЂ” В«No trackВ».
//   3. РќРµРїСѓСЃС‚Р°СЏ РѕС‡РµСЂРµРґСЊ: Р°РєС‚РёРІРЅС‹Р№ С‚СЂРµРє РїРѕРґСЃРІРµС‡РµРЅ РёРЅРґРёРєР°С‚РѕСЂРѕРј В«РёРіСЂР°РµС‚В»
//      (Icons.graphic_eq_rounded), РґР»РёС‚РµР»СЊРЅРѕСЃС‚СЊ РѕС‚С„РѕСЂРјР°С‚РёСЂРѕРІР°РЅР°.
//   4. РўР°Рї РїРѕ РІРєР»Р°РґРєРµ В«TrackВ» РїРµСЂРµРєР»СЋС‡Р°РµС‚ С‚РµР»Рѕ РїР°РЅРµР»Рё РЅР° В«No trackВ»
//      (РёСЃС‚РѕС‡РЅРёРє РґР°РЅРЅС‹С… Сѓ desktop-РїР»РµРµСЂР° РѕРґРёРЅ вЂ” trackQueue).
//
// РЎРµС‚СЊ РЅРµ РґС‘СЂРіР°РµРј: РїР»РµРµСЂ вЂ” _FakePlayer СЃ С„РёРєСЃРёСЂРѕРІР°РЅРЅРѕР№ trackQueue.

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

import '../setup/test_harness.dart';

/// Fake-РїР»РµРµСЂ: РїСЂРµРґРѕСЃС‚Р°РІР»СЏРµС‚ РѕС‡РµСЂРµРґСЊ [Track] РґР»СЏ QueuePanel.
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

    // РџСѓСЃС‚РѕР№ СЂРµРЅРґРµСЂ РЅРµ РґРѕР»Р¶РµРЅ Р±СЂРѕСЃР°С‚СЊ (ListView/Scrollbar Р±РµР· СЌР»РµРјРµРЅС‚РѕРІ).
    expect(tester.takeException(), isNull);

    // Р’РєР»Р°РґРєР° РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ вЂ” В«QueueВ» в†’ Р·Р°РіР»СѓС€РєР° В«Queue emptyВ».
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

    // РђРєС‚РёРІРЅС‹Р№ (РёРЅРґРµРєСЃ 0) С‚СЂРµРє РїРѕРґСЃРІРµС‡РµРЅ РёРЅРґРёРєР°С‚РѕСЂРѕРј В«РёРіСЂР°РµС‚В».
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

    // РћР±Р° Р·Р°РіРѕР»РѕРІРєР° Рё РёСЃРїРѕР»РЅРёС‚РµР»Рё РІРёРґРЅС‹.
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

    // РџРµСЂРµРєР»СЋС‡Р°РµРјСЃСЏ РЅР° РІРєР»Р°РґРєСѓ В«TrackВ».
    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();

    // Р”Р°РЅРЅС‹Рµ Сѓ desktop-РїР»РµРµСЂР° РѕРґРёРЅ вЂ” С‚Р° Р¶Рµ trackQueue. РџСѓСЃС‚С‹С… Р·Р°РіР»СѓС€РµРє РЅРµС‚.
    expect(find.text('Only Track'), findsOneWidget);
    expect(find.text('No track'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}