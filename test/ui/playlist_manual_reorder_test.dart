// Widget-тесты режима ручного редактирования порядка треков (manual sort)
// внутри PlaylistPage.
//
// Покрывают:
//   A. При выбранном режиме manual в sort-баре видна кнопка редактирования;
//      тап переводит страницу в reorder-режим (SliverReorderableList,
//      drag-хендлы, кнопка Done, кнопка редактирования исчезает).
//   B. В reorder-режиме drag трека с позиции 0 на позицию 2 меняет порядок
//      в PlaylistRepository; после Done + flush + reload порядок
//      персистится (считан из БД).
//   C. Кастомный порядок, сохранённый через репозиторий, отображается на
//      странице при выбранном manual (порядок заголовков треков = сохранённому).
//
// ─── FakeAsync-ловушки (паттерн playlist_reorder_test.dart) ───
//   * playlistsProvider override'ится СИНХРОННЫМ стримом из памяти — без
//     ensureLoaded(), иначе дедлок FakeAsync-зоны testWidgets;
//   * playlistSortModeProvider override'ится через
//     PlaylistSortModeNotifier.seeded(...) — без lazy-read закрытой БД
//     (дефолтный конструктор шедулит async _load() → sqflite_ffi чтение
//     после tearDown → падение);
//   * vibrationEnabledProvider override'ится через VibrationNotifier.seeded(...)
//     — тапы по кнопкам вызывают HapticHelper.*(ref:), который читает этот
//     провайдер; дефолтный VibrationNotifier() шедулит sqflite-read прямо в
//     FakeAsync-зоне → PendingTimerException (10-сек. sqflite lock-таймер);
//   * весь реальный I/O (create/addTrack/flush/reload) — только внутри
//     tester.runAsync(...);
//   * debounce-persist (Timer 300мс) от reorderTracks НЕ должен срабатывать
//     в FakeAsync-зоне (10-секундный sqflite lock-таймер повиснет с
//     PendingTimerException): после drag'а прогоняем строго < 300мс
//     fake-времени, а слив persist делаем через tester.runAsync(flush);
//   * pumpAndSettle НЕ используется — AnimatedPaletteNotifier держит
//     Ticker и settle виснет до таймаута. Вместо него pumpFrames().

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/repositories/playlist_repository.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/playlist_page.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый плеер (паттерн playlist_reorder_test.dart):
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
      throw UnimplementedError('not used in manual reorder test');

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

  // setUp/tearDown с реальным I/O (открытие/закрытие БД) — ВНЕ тестовой
  // FakeAsync-зоны: testWidgets оборачивает только тело теста.
  setUp(() async {
    await TestHarness.setUpDb();
    await PlaylistRepository.instance.resetForTesting();
    // Отключаем lazy-read БД в ArtworkHelper: getCustomArtworkSync шедулит
    // sqflite-транзакцию при построении _TrackArtwork в FakeAsync-зоне,
    // чей 10-сек. lock-таймер вешает тест (PendingTimerException).
    ArtworkHelper.disableDbReadsForTesting = true;
  });

  tearDown(() async {
    ArtworkHelper.disableDbReadsForTesting = false;
    await TestHarness.tearDownDb();
  });

  /// Большой viewport: страница со шапкой (artwork, кнопки) и списком
  /// треков должна вместиться без скролла, чтобы drag-хендлы были видимы
  /// для hit-test'а.
  void setupViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Синхронный стрим плейлистов из памяти репозитория — БЕЗ ensureLoaded()
  /// (иначе дедлок FakeAsync, см. шапку).
  Stream<List<Playlist>> playlistsFromMemory() async* {
    yield PlaylistRepository.instance.current;
    yield* PlaylistRepository.instance.stream;
  }

  Widget buildApp(String playlistId, PlaylistSortMode mode) {
    return ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(_FakePlayer()),
        playlistsProvider.overrideWith((ref) => playlistsFromMemory()),
        // Seeded-конструктор: без lazy-чтения БД (см. шапку).
        playlistSortModeProvider.overrideWith(
          (ref) => PlaylistSortModeNotifier.seeded(mode),
        ),
        // Seeded-вибрация: HapticHelper.*(ref:) при тапах читает этот
        // провайдер; дефолт шедулит sqflite-read в FakeAsync-зоне (см. шапку).
        vibrationEnabledProvider.overrideWith(
          (ref) => VibrationNotifier.seeded(true),
        ),
      ],
      child: MaterialApp(home: PlaylistPage(playlistId: playlistId)),
    );
  }

  /// Создаёт плейлист с тремя треками [A, B, C].
  /// Вызывать ТОЛЬКО внутри tester.runAsync — create/addTrack шедулят
  /// реальный persist-Timer.
  Future<Playlist> createPlaylistWithTracks() async {
    final repo = PlaylistRepository.instance;
    await repo.ensureLoaded();
    final p = repo.create('Manual Mix');
    const a = Track(id: '1', sourceId: 'muzmo', title: 'Song A', artist: 'X');
    const b = Track(id: '2', sourceId: 'muzmo', title: 'Song B', artist: 'Y');
    const c = Track(id: '3', sourceId: 'muzmo', title: 'Song C', artist: 'Z');
    repo.addTrack(p.id, a);
    repo.addTrack(p.id, b);
    repo.addTrack(p.id, c);
    // Даём debounce-persist (300мс) отработать в runAsync-зоне, чтобы
    // таймер не «переехал» в FakeAsync-зону и не повис.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return p;
  }

  /// Детерминированная замена pumpAndSettle (см. шапку про Ticker).
  Future<void> pumpFrames(
    WidgetTester tester, {
    int frames = 20,
    Duration step = const Duration(milliseconds: 50),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  List<String> trackIdsInRepo(String playlistId) => PlaylistRepository
      .instance.current
      .firstWhere((p) => p.id == playlistId)
      .tracks
      .map((t) => t.id)
      .toList();

  testWidgets(
    'A: manual mode shows edit button; tap enters reorder mode',
    (tester) async {
      setupViewport(tester);
      late Playlist p;
      await tester.runAsync(() async {
        p = await createPlaylistWithTracks();
      });
      await tester.pumpWidget(buildApp(p.id, PlaylistSortMode.manual));
      await pumpFrames(tester);

      // Кнопка редактирования видна в manual-режиме.
      expect(find.byKey(const ValueKey('edit_order_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('done_editing_button')), findsNothing);
      expect(find.byType(SliverReorderableList), findsNothing);

      await tester.tap(find.byKey(const ValueKey('edit_order_button')));
      await pumpFrames(tester);

      // Reorder-режим: drag-хендлы на каждом треке, кнопка Done,
      // индикатор режима, кнопка редактирования скрыта.
      expect(find.byType(SliverReorderableList), findsOneWidget);
      expect(
        find.byType(ReorderableDragStartListener),
        findsNWidgets(3),
      );
      expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(3));
      expect(find.byKey(const ValueKey('done_editing_button')), findsOneWidget);
      expect(find.text('Reorder tracks'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit_order_button')), findsNothing);

      // Done возвращает обычный режим. Тап — в runAsync: _finishEditingOrder
      // вызывает flush() с реальным sqflite I/O, который в FakeAsync-зоне
      // повис бы на 10-сек. lock-таймере (PendingTimerException).
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('done_editing_button')));
        // Даём flush() дойти до БД в реальном loop.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpFrames(tester);
      expect(find.byType(SliverReorderableList), findsNothing);
      expect(find.byKey(const ValueKey('edit_order_button')), findsOneWidget);
    },
  );

  testWidgets(
    'A2: edit button is hidden for non-manual sort mode',
    (tester) async {
      setupViewport(tester);
      late Playlist p;
      await tester.runAsync(() async {
        p = await createPlaylistWithTracks();
      });
      await tester.pumpWidget(buildApp(p.id, PlaylistSortMode.date));
      await pumpFrames(tester);

      expect(find.byKey(const ValueKey('edit_order_button')), findsNothing);
      expect(find.byType(SliverReorderableList), findsNothing);
    },
  );

  testWidgets(
    'B: drag track from 0 to 2, Done persists order (flush + reload)',
    (tester) async {
      setupViewport(tester);
      late Playlist p;
      await tester.runAsync(() async {
        p = await createPlaylistWithTracks();
      });
      await tester.pumpWidget(buildApp(p.id, PlaylistSortMode.manual));
      await pumpFrames(tester);

      expect(trackIdsInRepo(p.id), ['1', '2', '3']);

      // Входим в редактирование.
      await tester.tap(find.byKey(const ValueKey('edit_order_button')));
      await pumpFrames(tester);

      final firstHandle =
          find.byIcon(Icons.drag_handle_rounded).first;
      expect(firstHandle, findsOneWidget);
      final start = tester.getCenter(firstHandle);
      final thirdHandle = find.byIcon(Icons.drag_handle_rounded).at(2);
      final target = tester.getCenter(thirdHandle);

      // Drag за хендл (immediate, НЕ long-press). Весь жест — в runAsync
      // (реальный event loop): ReorderableList использует микротаски/таймеры
      // для построения drag-feedback и прокрутки; в FakeAsync-зоне перенос
      // надёжно не регистрируется. Промежуточные moveTo с pump — чтобы
      // список успел отреагировать на пересечение середины соседних item'ов.
      await tester.runAsync(() async {
        final gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 100));
        for (var i = 1; i <= 8; i++) {
          final t = i / 8;
          await gesture.moveTo(
            Offset(
              start.dx + (target.dx - start.dx) * t,
              start.dy + (target.dy - start.dy) * t,
            ),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        // Пауза над целью перед отпусканием — drop-логика должна
        // зафиксировать конечную позицию.
        await tester.pump(const Duration(milliseconds: 150));
        await gesture.up();
        // Небольшой реальный delay: persist-Timer (300мс) шедулится из
        // onReorder; здесь мы в runAsync, поэтому он реальный и не повиснет.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpFrames(tester);

      // onReorder(0, 3) → коррекция репозитория → A встал на позицию 2.
      expect(trackIdsInRepo(p.id), ['2', '3', '1']);

      // Done: выход из редактирования + flush внутри — тап в runAsync,
      // чтобы flush() отработал в реальном loop (см. тест A).
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('done_editing_button')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpFrames(tester);
      expect(find.byType(SliverReorderableList), findsNothing);

      // Гарантированный слив + перечитка из БД — в реальном event loop.
      await tester.runAsync(() async {
        await PlaylistRepository.instance.flush();
        await PlaylistRepository.instance.reload();
      });
      expect(trackIdsInRepo(p.id), ['2', '3', '1']);
    },
  );

  testWidgets(
    'C: saved custom order is displayed when manual mode is selected',
    (tester) async {
      setupViewport(tester);
      late Playlist p;
      await tester.runAsync(() async {
        p = await createPlaylistWithTracks();
        // Кастомный порядок через репозиторий: C, A, B.
        PlaylistRepository.instance.reorderTracks(p.id, 2, 0);
        await PlaylistRepository.instance.flush();
        await PlaylistRepository.instance.reload();
      });
      expect(trackIdsInRepo(p.id), ['3', '1', '2']);

      await tester.pumpWidget(buildApp(p.id, PlaylistSortMode.manual));
      await pumpFrames(tester);

      // Порядок заголовков треков на странице = сохранённому (C, A, B).
      // Тайлы идут в CustomScrollView — берём тексты в порядке hit-test.
      final titles = tester
          .widgetList<Text>(find.text('Song C'))
          .toList();
      expect(titles, isNotEmpty);

      // Строгая проверка порядка: центры тайлов по Y возрастают сверху вниз.
      final yC = tester.getCenter(find.text('Song C')).dy;
      final yA = tester.getCenter(find.text('Song A')).dy;
      final yB = tester.getCenter(find.text('Song B')).dy;
      expect(yC < yA && yA < yB, isTrue,
          reason: 'C выше A выше B — сохранённый manual-порядок отображён');
    },
  );
}
