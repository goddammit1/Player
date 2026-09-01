// Widget-тесты ручного переупорядочивания плейлистов (drag & drop на HomePage).
//
// Покрывают Этап 3 фичи «ручное переупорядочивание плейлистов»:
//   1. Long-press drag карточки на сетке меняет порядок в репозитории,
//      и новый порядок персистится (flush + reload).
//   2. Обычный тап по карточке НЕ стартует drag (нет feedback/childWhenDragging)
//      и НЕ меняет порядок — запасной вариант, разрешённый заданием, т.к.
//      реальная PlaylistPage в тестовом окружении падает (существующий
//      RenderFlex overflow в кнопке сортировки, playlist_page.dart:1046).
//   3. Ячейка «Add new» не является drop-целью: drop на неё не меняет
//      порядок.
//   4. Drag верхней карточки на самую нижнюю ставит элемент последним.
//
// ─── Дедлок FakeAsync (КРИТИЧНО, паттерн playlist_cache_menu_test.dart) ───
// Настоящий playlistsProvider делает `await ensureLoaded()` (реальный
// sqflite_ffi I/O) внутри FakeAsync-зоны testWidgets → жёсткий дедлок:
// фейковый event loop не обслуживает настоящий микрозадачный I/O. Поэтому:
//   * playlistsProvider override'ится СИНХРОННЫМ стримом из памяти
//     (repo.current + ретрансляция repo.stream) — без ensureLoaded();
//   * ВСЕ реальные БД-операции (create/flush/reload/resetForTesting/
//     ensureLoaded) выполняются через `tester.runAsync(...)`, которая
//     возвращает реальный event loop;
//   * debounce-persist (Timer 300мс) reorder'а НЕ должен срабатывать в
//     FakeAsync-зоне: иначе реальный _persistNow() запускает 10-секундный
//     sqflite lock-таймер транзакции, который виснет (PendingTimerException).
//     Поэтому после reorder-drag'ов persist сливается `flush()` через
//     `tester.runAsync` (см. flushPersistAndSettle), а longPressDragTo после
//     up прогоняет строго < 300мс fake-времени.
//
// Техника drag для LongPressDraggable (первый прецедент в проекте):
// `tester.startGesture(center)` → `pump(kLongPressTimeout + 50ms)` (ждём,
// пока long-press recognizer выиграет арену жестов) → `moveTo(target)` →
// `pump()` → `up()` → pumpFrames(). `tester.longPress()` не подходит:
// он завершает жест up'ом, не давая перетащить.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/repositories/playlist_repository.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/home_page.dart';
import 'package:player/ui/widgets/playlist_reorder_scope.dart';
import 'package:player/ui/widgets/reorderable_playlist_card.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый плеер (паттерн settings_page_back_button_test.dart).
/// HomePage не читает плеер напрямую, но animatedPaletteProvider →
/// currentPaletteProvider слушает mediaItem-поток плеера, поэтому
/// playerServiceProvider нужно подменить.
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
      throw UnimplementedError('not used in reorder test');

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
  // FakeAsync-зоны: testWidgets оборачивает ТОЛЬКО тело теста, а
  // setUp/tearDown бегут в реальном event loop, поэтому sqflite работает.
  setUp(() async {
    await TestHarness.setUpDb();
    await PlaylistRepository.instance.resetForTesting();
  });

  tearDown(() async {
    await TestHarness.tearDownDb();
  });

  /// Окно 1400x2200. ВАЖНО: flutter_test по умолчанию выставляет
  /// defaultTargetPlatform = android (даже на Windows-хосте), поэтому
  /// `isDesktop` = false и HomePage использует МОБИЛЬНУЮ сетку из 2 колонок
  /// (home_page.dart: crossAxisCount 2, childAspectRatio 0.82). При 3
  /// плейлистах + «Add new» сетка даёт 2 ряда, и второй ряд (one, AddNew)
  /// лежит НИЖЕ ~1400px. Чтобы все карточки были видимы без скролла (drag на
  /// невидимую карточку невозможен — hit-test промахивается за пределами
  /// окна, см. диагностику центров: one=(354,1406) при высоте 1000),
  /// высоты 2200 достаточно, чтобы вместить оба ряда целиком.
  void setupViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Синхронный стрим плейлистов из памяти репозитория — БЕЗ ensureLoaded()
  /// (иначе дедлок FakeAsync, см. шапку). Эмитит текущий снимок и
  /// ретранслирует все последующие изменения из repo.stream.
  Stream<List<Playlist>> playlistsFromMemory() async* {
    yield PlaylistRepository.instance.current;
    yield* PlaylistRepository.instance.stream;
  }

  Widget buildApp() {
    return ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(_FakePlayer()),
        playlistsProvider.overrideWith((ref) => playlistsFromMemory()),
      ],
      child: const MaterialApp(home: HomePage()),
    );
  }

  /// Создаёт три плейлиста через репозиторий. create() вставляет в начало,
  /// поэтому в UI порядок обратный созданию: [three, two, one].
  ///
  /// ВНИМАНИЕ: вызывать ТОЛЬКО внутри `tester.runAsync(...)` — create()
  /// шедулит реальный persist-Timer и дальше нужен настоящий event loop.
  Future<(Playlist, Playlist, Playlist)> createThree() async {
    final repo = PlaylistRepository.instance;
    await repo.ensureLoaded();
    final one = repo.create('One');
    final two = repo.create('Two');
    final three = repo.create('Three');
    // Даём debounce-persist (300мс) реально отработать в runAsync-зоне,
    // чтобы таймер не «переехал» в FakeAsync-зону и не повис.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return (one, two, three);
  }

  /// Детерминированная замена pumpAndSettle: прогоняет [frames] кадров
  /// с шагом [step]. pumpAndSettle здесь НЕ используется: HomePage держит
  /// AnimatedPaletteNotifier с Ticker'ом, который при drag форсирует кадры
  /// до таймаута теста (см. playlist_cache_menu_test.dart — та же причина
  /// на PlaylistPage с shimmer'ом). Конечного числа кадров достаточно, чтобы
  /// отработал стрим плейлистов, анимация входа и drop-логика DragTarget.
  Future<void> pumpFrames(
    WidgetTester tester, {
    int frames = 20,
    Duration step = const Duration(milliseconds: 50),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// Отрисовать HomePage и дождаться данных из (синхронного) стрима.
  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await pumpFrames(tester);
  }

  /// Long-press drag карточки с ключом [fromKey] в точку [target].
  ///
  /// Путь от старта до цели разбит на несколько промежуточных moveTo с pump
  /// (рекомендация задания: «при флаки — разбить на 2–3 промежуточных moveTo
  /// с pump»). Это надёжно будит DragTarget'ы по пути и стабилизирует drop.
  Future<void> longPressDragTo(
    WidgetTester tester, {
    required Key fromKey,
    required Offset target,
  }) async {
    final from = find.byKey(fromKey);
    expect(from, findsOneWidget);
    final start = tester.getCenter(from);
    final gesture = await tester.startGesture(start);
    // Ждём, пока long-press recognizer выиграет арену жестов (без движения,
    // чтобы drag не распознался как скролл CustomScrollView).
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // 4 промежуточных шага: каждый pointer-move будит DragTarget'ы по пути,
    // последний ставит палец ровно в точку drop.
    for (var i = 1; i <= 4; i++) {
      final t = i / 4;
      final step = Offset(
        start.dx + (target.dx - start.dx) * t,
        start.dy + (target.dy - start.dy) * t,
      );
      await gesture.moveTo(step);
      await tester.pump(const Duration(milliseconds: 30));
    }
    // Пауза НАД целью перед up: DragTarget цели должен получить pointer-move
    // и пометить candidateData ДО drop, иначе onAccept молча не вызовется
    // (наблюдалось на дальней по ряду карточке).
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    // ВАЖНО: после up прогоняем СТРОГО меньше 300мс fake-времени. onAccept
    // (синхронно при up) вызывает reorderPlaylists → запускается persist-
    // Timer(300мс). Если прогнать >= 300мс fake-времени, Timer сработает
    // ВНУТРИ FakeAsync-зоны и вызовет реальный sqflite _persistNow() →
    // 10-секундный lock-таймер транзакции повиснет (PendingTimerException).
    // Поэтому здесь лишь 2 кадра по 40мс (достаточно для регистрации drop и
    // rebuild), а слив persist (flush) и финальный settle — в самих тестах
    // через tester.runAsync (реальный event loop), см. тесты 1 и 4.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
  }

  /// Слить debounce-persist репозитория в реальном event loop и дать UI
  /// досесть. Вызывать ПОСЛЕ reorder-drag'ов: flush() отменяет pending
  /// persist-Timer (300мс) до его срабатывания в FakeAsync-зоне и выполняет
  /// запись в БД в реальном loop — это устраняет PendingTimerException от
  /// 10-секундного sqflite lock-таймера транзакции.
  Future<void> flushPersistAndSettle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await PlaylistRepository.instance.flush();
    });
    await pumpFrames(tester);
  }

  List<String> repoOrder() =>
      PlaylistRepository.instance.current.map((p) => p.id).toList();

  testWidgets(
    'long-press drag reorders playlist cards on home grid and persists',
    (tester) async {
      setupViewport(tester);
      late Playlist one, two, three;
      // Реальный I/O (create + persist) — в реальном event loop.
      await tester.runAsync(() async {
        final r = await createThree();
        one = r.$1;
        two = r.$2;
        three = r.$3;
      });
      await pumpHome(tester);

      // Исходный порядок в UI: [three, two, one].
      expect(repoOrder(), [three.id, two.id, one.id]);
      expect(find.byKey(ValueKey('reorder_${three.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('reorder_${two.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('reorder_${one.id}')), findsOneWidget);

      // Тянем Three (index 0) на центр Two (index 1).
      final target =
          tester.getCenter(find.byKey(ValueKey('reorder_${two.id}')));
      await longPressDragTo(
        tester,
        fromKey: ValueKey('reorder_${three.id}'),
        target: target,
      );

      expect(repoOrder(), [two.id, three.id, one.id]);

      // Сливаем debounce-persist в реальный loop ДО того, как его 300мс-таймер
      // сработает в FakeAsync-зоне (иначе 10s sqflite lock-таймер повиснет).
      await flushPersistAndSettle(tester);

      // Персистентность: reload (реальный I/O, перечитывает БД) → порядок
      // тот же, значит запись на диск действительно произошла.
      await tester.runAsync(() async {
        await PlaylistRepository.instance.reload();
      });
      expect(repoOrder(), [two.id, three.id, one.id]);
    },
  );

  testWidgets('plain tap does not start a drag and keeps order', (tester) async {
    // Вариант-запас, явно разрешённый заданием: «Если PlaylistPage в тестовом
    // окружении падает из-за плеерных зависимостей — вместо этого проверь,
    // что после tap порядок не изменился и drag НЕ стартовал (нет feedback
    // в overlay)». Реальная PlaylistPage в тесте ДЕЙСТВИТЕЛЬНО падает: тап
    // открывает её, и срабатывает СУЩЕСТВУЮЩИЙ (не связанный с reorder)
    // RenderFlex overflow 43px в кнопке сортировки (playlist_page.dart:1046,
    // Row в контейнере фикс. ширины 95px, метка "By artist" не влезает),
    // плюс PlaylistSortModeNotifier._load лениво читает уже закрытую
    // tearDown'ом БД. Обе проблемы — вне скоупа этапа 3 (только тесты
    // reorder). Поэтому контракт tap'а проверяется изолированно над
    // ReorderablePlaylistCard — тем самым виджетом, что использует HomePage:
    // tap по карточке НЕ вызывает onReorder и НЕ переводит карточку в
    // dragging-состояние (не появляется полупрозрачный childWhenDragging).
    var reorderCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 240,
              child: ReorderablePlaylistCard(
                index: 0,
                onReorder: (oldI, newI) => reorderCalls++,
                child: const ColoredBox(
                  color: Colors.blueGrey,
                  child: Center(child: Text('Card')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Короткий тап (down+up быстрее kLongPressTimeout).
    await tester.tap(find.text('Card'));
    // Даём recognizer'ам отработать: если бы tap ошибочно «залип» в
    // long-press, за эти кадры drag бы стартовал.
    await pumpFrames(tester, frames: 6);

    // Drag НЕ стартовал: нет полупрозрачного childWhenDragging (Opacity 0.25)
    // — маркера активного dragging...
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.25),
      findsNothing,
    );
    // ...и reorder НЕ вызывался (порядок бы не изменился).
    expect(reorderCalls, 0);
  });

  testWidgets('AddNewCard is not a drop target', (tester) async {
    setupViewport(tester);
    late Playlist one, two, three;
    await tester.runAsync(() async {
      final r = await createThree();
      one = r.$1;
      two = r.$2;
      three = r.$3;
    });
    await pumpHome(tester);

    final orderBefore = repoOrder();
    expect(orderBefore, [three.id, two.id, one.id]);

    // Маркер ячейки «Add new» — её текст.
    final addNew = find.text('Add new');
    expect(addNew, findsOneWidget);

    // Тянем Three (index 0) на центр кнопки добавления и отпускаем.
    await longPressDragTo(tester,
      fromKey: ValueKey('reorder_${three.id}'),
      target: tester.getCenter(addNew),
    );
    // onAccept не вызван (AddNew не DragTarget) → persist-Timer НЕ запущен,
    // поэтому долгий settle безопасен (нет риска PendingTimerException).
    await pumpFrames(tester);

    // _AddNewCard не обёрнут в DragTarget — порядок меняться не должен.
    expect(repoOrder(), orderBefore);
  });

  testWidgets('drag down to last position moves card to the end',
      (tester) async {
    setupViewport(tester);
    late Playlist one, two, three;
    await tester.runAsync(() async {
      final r = await createThree();
      one = r.$1;
      two = r.$2;
      three = r.$3;
    });
    await pumpHome(tester);

    // Исходно: [three, two, one].
    expect(repoOrder(), [three.id, two.id, one.id]);

    // Тянем Three (index 0) на центр One (последняя карточка, index 2).
    // one лежит во ВТОРОМ ряду 2-колоночной сетки — viewport 2200px высотой
    // (см. setupViewport) делает его видимым, иначе hit-test промахивается.
    await longPressDragTo(
      tester,
      fromKey: ValueKey('reorder_${three.id}'),
      target: tester.getCenter(find.byKey(ValueKey('reorder_${one.id}'))),
    );

    // Сливаем debounce-persist в реальный loop (см. flushPersistAndSettle).
    await flushPersistAndSettle(tester);

    // onReorder(0, 3) → после коррекции репозитория элемент встаёт последним.
    expect(repoOrder(), [two.id, one.id, three.id]);
  });

  // ─── Регрессия «живого» preview (баг «туда-обратно») ──────────────────
  // Корневая причина бага: PlaylistReorderScope.setHover игнорировал
  // index == draggingIndex, поэтому при возврате курсора над полупрозрачной
  // «дыркой» перетаскиваемой карточки (она тоже DragTarget) hoverIndex
  // залипал на последней чужой карточке → соседи НЕ возвращались в исходное
  // положение и визуально накладывались на «дырку». Фикс: setHover принимает
  // hover == dragging (карточки трактуют это как Offset.zero), а DragTarget
  // «дырки» принимает drop на себя как no-op (onReorder не вызывается).

  /// Смещение AnimatedSlide конкретной карточки [cardKey].
  Offset slideOffsetOf(WidgetTester tester, Key cardKey) {
    final slide = find.descendant(
      of: find.byKey(cardKey),
      matching: find.byType(AnimatedSlide),
    );
    expect(slide, findsOneWidget, reason: 'AnimatedSlide карточки $cardKey');
    return tester.widget<AnimatedSlide>(slide).offset;
  }

  testWidgets(
    'drag forward then back onto own hole restores preview (no stuck shift)',
    (tester) async {
      setupViewport(tester);
      late Playlist one, two, three;
      await tester.runAsync(() async {
        final r = await createThree();
        one = r.$1;
        two = r.$2;
        three = r.$3;
      });
      await pumpHome(tester);

      // Исходно: [three(0), two(1), one(2)].
      expect(repoOrder(), [three.id, two.id, one.id]);
      final threeKey = ValueKey('reorder_${three.id}');
      final twoKey = ValueKey('reorder_${two.id}');
      final oneKey = ValueKey('reorder_${one.id}');

      // Стартуем long-press drag карточки Three (index 0) — БЕЗ up.
      final start = tester.getCenter(find.byKey(threeKey));
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      // Тянем ВПЕРЁД на центр One (index 2, второй ряд): hoverIndex = 2.
      final oneCenter = tester.getCenter(find.byKey(oneKey));
      await gesture.moveTo(oneCenter);
      await tester.pump(const Duration(milliseconds: 50));

      // Preview «вперёд»: hover(2) != dragging(0) → Two и One сдвинуты
      // (получили ненулевую цель анимации). Не ждём окончания AnimatedSlide
      // (300мс-персист-ловушка) — достаточно, что цель ненулевая.
      expect(slideOffsetOf(tester, twoKey), isNot(Offset.zero),
          reason: 'drag вперёд: Two должен сдвинуться назад на ячейку 0');
      expect(slideOffsetOf(tester, oneKey), isNot(Offset.zero),
          reason: 'drag вперёд: One должен сдвинуться назад на ячейку 1');

      // Возвращаем курсор НА ИСХОДНУЮ ячейку (над «дыркой» Three).
      // До фикса setHover игнорировал index == draggingIndex → hoverIndex
      // залипал на 2, соседи не возвращались (баг).
      await gesture.moveTo(start);
      await tester.pump(const Duration(milliseconds: 50));

      // После фикса hoverIndex = 0 == draggingIndex → все preview-смещения
      // откатываются в Offset.zero (нет наложения, состояние = «как было»).
      expect(slideOffsetOf(tester, twoKey), Offset.zero,
          reason: 'возврат на исходную ячейку: Two должен вернуться');
      expect(slideOffsetOf(tester, oneKey), Offset.zero,
          reason: 'возврат на исходную ячейку: One должен вернуться');

      // Drop на собственную «дырку» — no-op (onReorder НЕ вызывается) и
      // состояние scope очищается.
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(repoOrder(), [three.id, two.id, one.id],
          reason: 'drop на свою «дырку» не должен менять порядок');
    },
  );

  testWidgets('scope setHover accepts hoverIndex == draggingIndex',
      (tester) async {
      // Изолированный тест контракта scope: hoverIndex может равняться
      // draggingIndex (валидное состояние «вернуть как было»), а endDrag
      // полностью очищает оба индекса. Именно этот фильтр
      // (index == draggingIndex → return) был корнем бага.
      final scopeKey = GlobalKey<PlaylistReorderScopeState>();
      await tester.pumpWidget(
        MaterialApp(
          home: PlaylistReorderScope(
            key: scopeKey,
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            child: const SizedBox.shrink(),
          ),
        ),
      );

      final scope = scopeKey.currentState!;
      expect(scope.draggingIndex, isNull);
      expect(scope.hoverIndex, isNull);

      // Начинаем drag карточки 0, тянем над карточку 2, затем обратно над
      // «дырку» 0: hoverIndex обязан стать 0 (== draggingIndex), не залипнуть.
      scope.startDrag(0);
      await tester.pump();
      scope.setHover(2);
      await tester.pump();
      expect(scope.hoverIndex, 2);
      scope.setHover(0);
      await tester.pump();
      expect(scope.draggingIndex, 0);
      expect(scope.hoverIndex, 0,
          reason: 'hoverIndex должен принимать значение draggingIndex');

      // endDrag чистит состояние полностью.
      scope.endDrag();
      await tester.pump();
      expect(scope.draggingIndex, isNull);
      expect(scope.hoverIndex, isNull);
    },
  );
}
