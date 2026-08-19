// Regression-тест десктопного поиска.
//
// История: в Windows-версии верхняя строка была кнопкой-заглушкой,
// которая открывала страницу поиска со второй (настоящей) строкой ввода.
// Теперь верхняя строка — ЕДИНАЯ строка поиска (DesktopSearchBar/TextField):
// ввод + Enter запускают поиск по источникам и показывают результаты в
// контентной области окна (SearchPage без собственной строки ввода).
//
// Тест рендерит настоящий DesktopShell и проверяет весь сценарий:
//   1) в верхней панели есть TextField (а не «кнопка Search»);
//   2) после Enter-поиска контентная область показывает SearchPage
//      без строки ввода внутри страницы (showInPageSearchBar: false);
//   3) найденный трек отображается в результатах;
//   4) очистка возвращает контент к разделу плейлистов.
//
// Сеть не дёргаем: в SourceRegistry регистрируется один _FakeSource.

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
import 'package:player/ui/pages/search_page.dart';

import 'setup/test_harness.dart';

/// Fake-плеер: только чтобы playerServiceProvider был валиден в ProviderScope.
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

/// Fake-источник поиска (без сети).
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
    // Один зарегистрированный источник — поиск завершается быстро.
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
    // Не используем pumpAndSettle: в IndexedStack живут все разделы сразу
    // (в т.ч. SettingsPage с вечными анимациями), поэтому ждём явные кадры.
    await tester.pump();

    // 1) Верхняя панель содержит настоящее поле ввода поиска.
    expect(find.byType(TextField), findsOneWidget);

    // 2) Изначально (пустой запрос) контент показывает плейлисты,
    //    SearchPage отсутствует.
    expect(find.byType(SearchPage), findsNothing);

    // 3) Вводим запрос и жмём Enter.
    await tester.enterText(find.byType(TextField), 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // Даём асинхронному поиску завершиться (fake-источник отвечает мгновенно)
    // и доиграть короткой анимации bar (350 мс у SearchPage).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    // Запрос записан в searchProvider; найденный трек показан в контентной
    // области.
    expect(find.byType(SearchPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
      findsNothing,
      reason: 'На десктопе SearchPage НЕ должен содержать свою строку ввода',
    );
    expect(find.text('Found Song One'), findsOneWidget);

    // 4) Очистка возвращает контент к разделу плейлистов.
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.byType(SearchPage), findsNothing);
  });
}
