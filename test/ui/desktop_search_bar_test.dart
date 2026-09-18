// Regression-С‚РµСЃС‚ РґРµСЃРєС‚РѕРїРЅРѕРіРѕ РїРѕРёСЃРєР°.
//
// РСЃС‚РѕСЂРёСЏ: РІ Windows-РІРµСЂСЃРёРё РІРµСЂС…РЅСЏСЏ СЃС‚СЂРѕРєР° Р±С‹Р»Р° РєРЅРѕРїРєРѕР№-Р·Р°РіР»СѓС€РєРѕР№,
// РєРѕС‚РѕСЂР°СЏ РѕС‚РєСЂС‹РІР°Р»Р° СЃС‚СЂР°РЅРёС†Сѓ РїРѕРёСЃРєР° СЃРѕ РІС‚РѕСЂРѕР№ (РЅР°СЃС‚РѕСЏС‰РµР№) СЃС‚СЂРѕРєРѕР№ РІРІРѕРґР°.
// РўРµРїРµСЂСЊ РІРµСЂС…РЅСЏСЏ СЃС‚СЂРѕРєР° вЂ” Р•Р”РРќРђРЇ СЃС‚СЂРѕРєР° РїРѕРёСЃРєР° (DesktopSearchBar/TextField):
// РІРІРѕРґ + Enter Р·Р°РїСѓСЃРєР°СЋС‚ РїРѕРёСЃРє РїРѕ РёСЃС‚РѕС‡РЅРёРєР°Рј Рё РїРѕРєР°Р·С‹РІР°СЋС‚ СЂРµР·СѓР»СЊС‚Р°С‚С‹ РІ
// РєРѕРЅС‚РµРЅС‚РЅРѕР№ РѕР±Р»Р°СЃС‚Рё РѕРєРЅР° (SearchPage Р±РµР· СЃРѕР±СЃС‚РІРµРЅРЅРѕР№ СЃС‚СЂРѕРєРё РІРІРѕРґР°).
//
// РўРµСЃС‚ СЂРµРЅРґРµСЂРёС‚ РЅР°СЃС‚РѕСЏС‰РёР№ DesktopShell Рё РїСЂРѕРІРµСЂСЏРµС‚ РІРµСЃСЊ СЃС†РµРЅР°СЂРёР№:
//   1) РІ РІРµСЂС…РЅРµР№ РїР°РЅРµР»Рё РµСЃС‚СЊ TextField (Р° РЅРµ В«РєРЅРѕРїРєР° SearchВ»);
//   2) РїРѕСЃР»Рµ Enter-РїРѕРёСЃРєР° РєРѕРЅС‚РµРЅС‚РЅР°СЏ РѕР±Р»Р°СЃС‚СЊ РїРѕРєР°Р·С‹РІР°РµС‚ SearchPage
//      Р±РµР· СЃС‚СЂРѕРєРё РІРІРѕРґР° РІРЅСѓС‚СЂРё СЃС‚СЂР°РЅРёС†С‹ (showInPageSearchBar: false);
//   3) РЅР°Р№РґРµРЅРЅС‹Р№ С‚СЂРµРє РѕС‚РѕР±СЂР°Р¶Р°РµС‚СЃСЏ РІ СЂРµР·СѓР»СЊС‚Р°С‚Р°С…;
//   4) РѕС‡РёСЃС‚РєР° РІРѕР·РІСЂР°С‰Р°РµС‚ РєРѕРЅС‚РµРЅС‚ Рє СЂР°Р·РґРµР»Сѓ РїР»РµР№Р»РёСЃС‚РѕРІ.
//
// РЎРµС‚СЊ РЅРµ РґС‘СЂРіР°РµРј: РІ SourceRegistry СЂРµРіРёСЃС‚СЂРёСЂСѓРµС‚СЃСЏ РѕРґРёРЅ _FakeSource.

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
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';
import 'package:player/ui/desktop/desktop_shell.dart';
import 'package:player/ui/desktop/desktop_top_bar.dart';
import 'package:player/ui/pages/search_page.dart';

import '../setup/test_harness.dart';

/// Fake-РїР»РµРµСЂ: С‚РѕР»СЊРєРѕ С‡С‚РѕР±С‹ playerServiceProvider Р±С‹Р» РІР°Р»РёРґРµРЅ РІ ProviderScope.
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
      throw UnimplementedError('not used in desktop search test');

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

/// Fake-РёСЃС‚РѕС‡РЅРёРє РїРѕРёСЃРєР° (Р±РµР· СЃРµС‚Рё).
class _FakeSource extends TrackSource {
  _FakeSource({required this.id, this.displayName = ''});

  @override
  final String id;
  @override
  final String displayName;

  List<Track> result = const [];

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async => result;

  @override
  Future<String> resolveStreamUrl(Track track) async =>
      'https://example.com/stream.mp3';

  @override
  Future<void> dispose() async {}
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  Widget buildApp() {
    return ProviderScope(
      overrides: [playerServiceProvider.overrideWithValue(_FakePlayer())],
      child: const MaterialApp(home: DesktopShell()),
    );
  }

  testWidgets(
      'top bar is a real search field (not a navigational Search button) that '
      'updates the provider and shows results in the content area '
      'without an in-page search bar', (tester) async {
    // РћРґРёРЅ Р·Р°СЂРµРіРёСЃС‚СЂРёСЂРѕРІР°РЅРЅС‹Р№ РёСЃС‚РѕС‡РЅРёРє вЂ” РїРѕРёСЃРє Р·Р°РІРµСЂС€Р°РµС‚СЃСЏ Р±С‹СЃС‚СЂРѕ.
    final source = _FakeSource(id: 'fake_a', displayName: 'Fake A')
      ..result = [
        Track(
          id: 'a1',
          sourceId: 'fake_a',
          title: 'Found Song One',
          artist: 'Artist A',
        ),
      ];
    SourceRegistry.instance.register(source);
    addTearDown(() async => await SourceRegistry.instance.disposeAll());

    await tester.pumpWidget(buildApp());
    // РќРµ РёСЃРїРѕР»СЊР·СѓРµРј pumpAndSettle: РІ IndexedStack Р¶РёРІСѓС‚ РІСЃРµ СЂР°Р·РґРµР»С‹ СЃСЂР°Р·Сѓ
    // (РІ С‚.С‡. SettingsPage СЃ РІРµС‡РЅС‹РјРё Р°РЅРёРјР°С†РёСЏРјРё), РїРѕСЌС‚РѕРјСѓ Р¶РґС‘Рј СЏРІРЅС‹Рµ РєР°РґСЂС‹.
    await tester.pump();

    // 1) Р’РµСЂС…РЅСЏСЏ РїР°РЅРµР»СЊ СЃРѕРґРµСЂР¶РёС‚ РЅР°СЃС‚РѕСЏС‰РµРµ РїРѕР»Рµ РІРІРѕРґР° РїРѕРёСЃРєР°.
    expect(find.byType(TextField), findsOneWidget);

    // 2) РР·РЅР°С‡Р°Р»СЊРЅРѕ (РїСѓСЃС‚РѕР№ Р·Р°РїСЂРѕСЃ) РєРѕРЅС‚РµРЅС‚ РїРѕРєР°Р·С‹РІР°РµС‚ РїР»РµР№Р»РёСЃС‚С‹,
    //    SearchPage РѕС‚СЃСѓС‚СЃС‚РІСѓРµС‚.
    expect(find.byType(SearchPage), findsNothing);

    // 3) Р’РІРѕРґРёРј Р·Р°РїСЂРѕСЃ Рё Р¶РјС‘Рј Enter.
    await tester.enterText(find.byType(TextField), 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // Р”Р°С‘Рј Р°СЃРёРЅС…СЂРѕРЅРЅРѕРјСѓ РїРѕРёСЃРєСѓ Р·Р°РІРµСЂС€РёС‚СЊСЃСЏ (fake-РёСЃС‚РѕС‡РЅРёРє РѕС‚РІРµС‡Р°РµС‚ РјРіРЅРѕРІРµРЅРЅРѕ)
    // Рё РґРѕРёРіСЂР°С‚СЊ РєРѕСЂРѕС‚РєРѕР№ Р°РЅРёРјР°С†РёРё bar (350 РјСЃ Сѓ SearchPage).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    // Р—Р°РїСЂРѕСЃ Р·Р°РїРёСЃР°РЅ РІ searchProvider; РЅР°Р№РґРµРЅРЅС‹Р№ С‚СЂРµРє РїРѕРєР°Р·Р°РЅ РІ РєРѕРЅС‚РµРЅС‚РЅРѕР№
    // РѕР±Р»Р°СЃС‚Рё.
    expect(find.byType(SearchPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
      findsNothing,
      reason: 'РќР° РґРµСЃРєС‚РѕРїРµ SearchPage РќР• РґРѕР»Р¶РµРЅ СЃРѕРґРµСЂР¶Р°С‚СЊ СЃРІРѕСЋ СЃС‚СЂРѕРєСѓ РІРІРѕРґР°',
    );
    expect(find.text('Found Song One'), findsOneWidget);

    // 4) РћС‡РёСЃС‚РєР° РІРѕР·РІСЂР°С‰Р°РµС‚ РєРѕРЅС‚РµРЅС‚ Рє СЂР°Р·РґРµР»Сѓ РїР»РµР№Р»РёСЃС‚РѕРІ.
    // Clear button is a custom _ClearButton without Tooltip: locate its icon
    // inside the top bar.
    await tester.tap(find.descendant(
      of: find.byType(DesktopTopBar),
      matching: find.byIcon(Icons.close_rounded),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(SearchPage), findsNothing);
  });
}
