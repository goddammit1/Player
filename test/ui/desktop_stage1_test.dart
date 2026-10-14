// Этап 1 паритета десктопа (plans/desktop_parity_plan.md):
//   1.1 контекстное меню трека по правому клику;
//   1.2 очередь: удаление по hover, «Clear», reorder за drag-handle,
//       видимость панели (DesktopSidePanelNotifier);
//   1.3 вкладка «Track» — текущий трек, смена обложки по hover;
//   1.4 плеер-бар: кнопка очереди, клик по треку, без фолбэков
//       'Muzmo' / '320 kbps';
//   1.5 выпадающая история поиска в top bar.
//
// Записей в БД из тапов нет: история поиска — in-memory notifier
// (sqflite в widget-тестах виснет), плеер — фейк, записывающий вызовы.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/desktop/desktop_player_bar.dart';
import 'package:player/ui/desktop/desktop_top_bar.dart';
import 'package:player/ui/desktop/desktop_ui_state.dart';
import 'package:player/ui/desktop/queue_panel.dart';
import 'package:player/ui/pages/search/search_track_tiles.dart';

import '../setup/test_harness.dart';

const _t1 = Track(id: 'q1', sourceId: 'fake_a', title: 'First', artist: 'A1');
const _t2 = Track(id: 'q2', sourceId: 'fake_a', title: 'Second', artist: 'A2');
const _t3 = Track(id: 'q3', sourceId: 'fake_a', title: 'Third', artist: 'A3');

/// Фейк-плеер с живыми потоками очереди / индекса / MediaItem и журналом
/// вызовов мутаций.
class _FakePlayer implements PlayerServiceInterface {
  _FakePlayer({List<Track> queue = const [], int current = -1, MediaItem? item})
      : _queue = [...queue],
        _index = BehaviorSubject.seeded(current),
        _item = BehaviorSubject.seeded(item) {
    _queueSubject = BehaviorSubject.seeded(List.unmodifiable(_queue));
  }

  final List<Track> _queue;
  late final BehaviorSubject<List<Track>> _queueSubject;
  final BehaviorSubject<int> _index;
  final BehaviorSubject<MediaItem?> _item;
  final calls = <String>[];

  void _emit() => _queueSubject.add(List.unmodifiable(_queue));

  @override
  List<Track> get trackQueue => List.unmodifiable(_queue);
  @override
  Stream<List<Track>> get trackQueueStream => _queueSubject.stream;
  @override
  int get currentIndex => _index.value;
  @override
  Stream<int> get currentIndexStream => _index.stream;
  @override
  Stream<MediaItem?> get mediaItem => _item.stream;
  @override
  MediaItem? get mediaItemValue => _item.value;

  @override
  Future<void> removeFromQueue(int index) async {
    calls.add('remove:$index');
    _queue.removeAt(index);
    _emit();
  }

  @override
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    calls.add('reorder:$oldIndex->$newIndex');
    _queue.insert(newIndex, _queue.removeAt(oldIndex));
    _emit();
  }

  @override
  Future<void> clearQueue() async {
    calls.add('clear');
    _queue.clear();
    _index.add(-1);
    _emit();
  }

  @override
  Future<void> insertToQueue(Track track) async =>
      calls.add('insert:${track.id}');

  @override
  Future<void> addToQueue(Track track) async => calls.add('add:${track.id}');

  @override
  Future<void> skipToQueueItem(int index) async => calls.add('skip:$index');

  // ---- Не используются в этих тестах ----
  @override
  bool get isLoading => false;
  @override
  double get boostDb => 0;
  @override
  Stream<double> get boostDbStream => BehaviorSubject.seeded(0.0).stream;
  @override
  void setBoost(double db) => calls.add('boost:${db.round()}');
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
  Future<void> stop() async {}
  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {}
  @override
  Future<void> playIndex(int index) async {}
  @override
  Future<void> shuffleQueue() async {}
  @override
  Future<void> updateCustomArtwork(String trackId, String newPath) async {}
  @override
  Future<void> resetCustomArtwork(String trackId) async {}
  @override
  Future<void> saveSession() async {}
}

/// История поиска в памяти: мутации не трогают БД.
class _MemoryHistory extends SearchHistoryNotifier {
  _MemoryHistory(super.initial) : super.seeded();

  @override
  Future<void> add(String query) async =>
      state = [query, ...state.where((e) => e != query)];

  @override
  Future<void> remove(String query) async =>
      state = state.where((e) => e != query).toList();

  @override
  Future<void> clear() async => state = const [];
}

/// Один мышиный указатель на тест (второй addPointer того же устройства
/// роняет MouseTracker).
TestGesture? _mouse;

Future<void> _hover(WidgetTester tester, Finder finder) async {
  if (_mouse == null) {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    _mouse = gesture;
    addTearDown(() async {
      await gesture.removePointer();
      _mouse = null;
    });
  }
  await _mouse!.moveTo(tester.getCenter(finder));
  await tester.pump();
}

/// Меню трека ждёт кэш-статус до 400 мс (stat файла — в FakeAsync он не
/// завершается), затем открывается без пункта Download.
Future<void> _openMenu(WidgetTester tester, Finder target) async {
  await tester.tap(
    target,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  void desktopView(WidgetTester tester, {Size size = const Size(1280, 800)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('DesktopSidePanelNotifier', () {
    test('wide window: queue button toggles docked panel, track click shows '
        'Track tab', () {
      final n = DesktopSidePanelNotifier();
      expect(n.state.visibleAt(1280), isTrue);

      n.toggleQueue(1280); // открыта на Queue → закрыть
      expect(n.state.visibleAt(1280), isFalse);

      n.showTrack(1280);
      expect(n.state.visibleAt(1280), isTrue);
      expect(n.state.tab, DesktopSideTab.track);

      n.toggleQueue(1280); // открыта на Track → переключить на Queue
      expect(n.state.visibleAt(1280), isTrue);
      expect(n.state.tab, DesktopSideTab.queue);
    });

    test('narrow window: overlay is closed by default and opens on demand',
        () {
      final n = DesktopSidePanelNotifier();
      expect(n.state.visibleAt(800), isFalse);

      n.toggleQueue(800);
      expect(n.state.visibleAt(800), isTrue);
      // Докинг в широком окне не затронут.
      expect(n.state.docked, isTrue);

      n.closeOverlay();
      expect(n.state.visibleAt(800), isFalse);
    });
  });

  group('QueuePanel', () {
    Widget wrap(_FakePlayer player) => ProviderScope(
          overrides: [playerServiceProvider.overrideWithValue(player)],
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(width: 360, height: 700, child: QueuePanel()),
              ),
            ),
          ),
        );

    testWidgets('hover × removes a queued track; current track has no ×',
        (tester) async {
      desktopView(tester);
      final player = _FakePlayer(queue: [_t1, _t2, _t3], current: 0);
      await tester.pumpWidget(wrap(player));
      await tester.pump();

      expect(find.text('3 tracks'), findsOneWidget);

      await _hover(tester, find.text('First'));
      expect(find.byKey(const ValueKey('queue_remove_0')), findsNothing);

      await _hover(tester, find.text('Second'));
      await tester.tap(find.byKey(const ValueKey('queue_remove_1')));
      await tester.pump();

      expect(player.calls, ['remove:1']);
      expect(find.text('Second'), findsNothing);
      expect(find.text('2 tracks'), findsOneWidget);
    });

    testWidgets('Clear asks for confirmation and clears the queue',
        (tester) async {
      desktopView(tester);
      final player = _FakePlayer(queue: [_t1, _t2], current: 0);
      await tester.pumpWidget(wrap(player));
      await tester.pump();

      await tester.tap(find.byKey(const Key('queue_clear')));
      await tester.pumpAndSettle();
      expect(find.text('Clear queue'), findsOneWidget);

      // Подтверждение — последняя «Clear» (первая — кнопка шапки очереди).
      await tester.tap(find.text('Clear').last);
      await tester.pumpAndSettle();

      expect(player.calls, ['clear']);
      expect(find.text('Queue is empty'), findsOneWidget);
    });

    testWidgets('dragging the handle reorders the queue', (tester) async {
      desktopView(tester);
      final player = _FakePlayer(queue: [_t1, _t2, _t3], current: 0);
      await tester.pumpWidget(wrap(player));
      await tester.pump();

      await _hover(tester, find.text('Third'));
      final handle = find.byKey(const ValueKey('queue_drag_2'));
      final drag = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 50));
      // Плитка ~88 px: поднимаем «Third» выше «Second».
      await drag.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 50));
      await drag.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 50));
      await drag.up();
      await tester.pumpAndSettle();

      expect(player.calls, ['reorder:2->1']);
      expect(player.trackQueue.map((t) => t.id), ['q1', 'q3', 'q2']);
    });

    testWidgets('right-click on a queued track offers Play now / Remove',
        (tester) async {
      desktopView(tester);
      final player = _FakePlayer(queue: [_t1, _t2, _t3], current: 0);
      await tester.pumpWidget(wrap(player));
      await tester.pump();

      await _openMenu(tester, find.text('Third'));
      expect(find.text('Play now'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      // Play next / Add to queue общего меню задублировали бы трек.
      expect(find.byKey(const Key('track_menu_add_to_queue')), findsNothing);

      await tester.tap(find.text('Remove from queue'));
      await tester.pumpAndSettle();
      expect(player.calls, ['remove:2']);
    });

    testWidgets('Track tab shows the current track and a hover cover action',
        (tester) async {
      desktopView(tester);
      final player = _FakePlayer(
        queue: [_t1],
        current: 0,
        item: const MediaItem(
          id: 'fake_a_q1',
          title: 'Now Playing Title',
          artist: 'Now Artist',
          extras: {'sourceId': 'fake_a', 'trackId': 'q1'},
        ),
      );
      await tester.pumpWidget(wrap(player));
      await tester.pump();

      await tester.tap(find.text('Track'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Now Playing Title'), findsOneWidget);
      expect(find.text('Now Artist'), findsOneWidget);
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);


      final cover = find.byKey(const Key('now_playing_change_cover'));
      expect(
        tester.widget<AnimatedOpacity>(
          find.ancestor(of: cover, matching: find.byType(AnimatedOpacity)),
        ).opacity,
        0.0,
      );
      await _hover(tester, find.text('Now Playing Title'));
      await _hover(tester, cover);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<AnimatedOpacity>(
          find.ancestor(of: cover, matching: find.byType(AnimatedOpacity)),
        ).opacity,
        1.0,
      );

      // Boost на десктопе виден и управляет плеером.
      final boost = find.byKey(const Key('now_playing_boost'));
      expect(boost, findsOneWidget);
      expect(find.text('Boost'), findsOneWidget);
      await tester.ensureVisible(boost);
      await tester.pump();
      final paint = find.descendant(
        of: boost,
        matching: find.byType(GestureDetector),
      );
      await tester.tapAt(tester.getCenter(paint.first) +
          Offset(tester.getSize(paint.first).width / 2 - 1, 0));
      await tester.pump();
      expect(player.calls, contains('boost:12'));
      expect(tester.takeException(), isNull);
    });
  });

  group('DesktopPlayerBar', () {
    Widget wrap(_FakePlayer player, ProviderContainer container) =>
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: DesktopPlayerBar.height,
                  child: Overlay(
                    initialEntries: [
                      OverlayEntry(builder: (_) => const DesktopPlayerBar()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('queue button and track click drive the side panel; no fake '
        'source / quality fallbacks', (tester) async {
      desktopView(tester);
      final player = _FakePlayer(
        queue: [_t1],
        current: 0,
        item: const MediaItem(id: 'fake_a_q1', title: 'Bar Title', artist: 'X'),
      );
      final container = ProviderContainer(
        overrides: [playerServiceProvider.overrideWithValue(player)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(wrap(player, container));
      await tester.pump();

      expect(find.textContaining('Muzmo'), findsNothing);
      expect(find.textContaining('320'), findsNothing);

      await tester.tap(find.byKey(const Key('bar_queue_toggle')));
      await tester.pump();
      expect(container.read(desktopSidePanelProvider).docked, isFalse);

      await tester.tap(find.byKey(const Key('bar_track_info')));
      await tester.pump();
      final panel = container.read(desktopSidePanelProvider);
      expect(panel.docked, isTrue);
      expect(panel.tab, DesktopSideTab.track);
    });
  });

  group('DesktopTopBar search history', () {
    Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Column(children: [DesktopTopBar(), Spacer()]),
            ),
          ),
        );

    ProviderContainer makeContainer(List<String> history) {
      final c = ProviderContainer(
        overrides: [
          playerServiceProvider.overrideWithValue(_FakePlayer()),
          searchHistoryProvider.overrideWith((ref) => _MemoryHistory(history)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('focus on empty field shows recent searches; arrows + Enter '
        'run the highlighted query', (tester) async {
      desktopView(tester);
      final container = makeContainer(['beatles', 'queen']);
      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('search_history_dropdown')), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byKey(const Key('search_history_dropdown')), findsOneWidget);
      expect(find.text('beatles'), findsOneWidget);
      expect(find.text('queen'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(container.read(searchProvider).query, 'queen');
      expect(container.read(searchHistoryProvider), ['queen', 'beatles']);
    });

    testWidgets('× removes a query, Clear all empties history, Esc closes',
        (tester) async {
      desktopView(tester);
      final container = makeContainer(['beatles', 'queen', 'abba']);
      await tester.pumpWidget(wrap(container));
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('search_history_remove_queen')),
      );
      await tester.pump();
      expect(container.read(searchHistoryProvider), ['beatles', 'abba']);
      // Клик внутри выпадашки не снимает фокус с поля.
      expect(find.byKey(const Key('search_history_dropdown')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('search_history_dropdown')), findsNothing);

      // Набор и стирание текста снова показывают историю.
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(find.byKey(const Key('search_history_clear')));
      await tester.pump();
      expect(container.read(searchHistoryProvider), isEmpty);
      expect(find.byKey(const Key('search_history_dropdown')), findsNothing);
    });
  });

  group('Track context menu', () {
    testWidgets('right-click on a search result: Play next queues the track',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      desktopView(tester);
      final player = _FakePlayer();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerServiceProvider.overrideWithValue(player)],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => SearchTrackTileList(
                  track: _t2,
                  isPlaying: false,
                  onTap: () {},
                  colors: ref.watch(animatedPaletteProvider),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await _openMenu(tester, find.text('Second'));
      expect(find.byKey(const Key('track_menu_play_next')), findsOneWidget);
      expect(find.byKey(const Key('track_menu_add_to_playlist')), findsOneWidget);
      expect(find.byKey(const Key('track_menu_details')), findsOneWidget);

      await tester.tap(find.byKey(const Key('track_menu_play_next')));
      await tester.pump();
      expect(player.calls, ['insert:q2']);

      // Снэкбар подтверждения уходит по таймеру.
      await tester.pump(const Duration(seconds: 3));
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
