// Regression-тест фильтра поиска по источникам (SearchFilterChips).
//
// История бага: когда пользователь выбирал конкретный источник, а по нему
// не было результатов, панель фильтров целиком скрывалась (условие
// `results.isNotEmpty || loading` в SearchPage). Из-за этого вернуться к
// «все источники» (тап по активному чипу) становилось невозможно — только
// сброс данных приложения.
//
// Тест рендерит настоящий SearchPage с настоящим SearchController (объявлен
// в ProviderScope без override), заводит состояние «выбран источник,
// результатов 0» и проверяет:
//   1) иконки фильтров по-прежнему видны;
//   2) тап по активному чипу возвращает источник на kAllSourcesId.
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
import 'package:player/search/search.dart' as search;
import 'package:player/sources/source_registry.dart';
import 'package:player/sources/track_source.dart';
import 'package:player/ui/pages/search_page.dart';

import '../setup/test_harness.dart';

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
      throw UnimplementedError('not used in this test');

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

/// Fake-источник поиска (без сети): всегда возвращает пустой результат.
class _EmptySource extends TrackSource {
  _EmptySource({required this.id, this.displayName = ''});

  @override
  final String id;

  @override
  final String displayName;

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async => const [];

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

  testWidgets(
      'filter chips stay visible when the selected source has 0 results and '
      'allow returning to all sources', (tester) async {
    // Два зарегистрированных источника — из них строятся чипы фильтров.
    final sourceA = _EmptySource(id: 'fake_a', displayName: 'Fake A');
    final sourceB = _EmptySource(id: 'fake_b', displayName: 'Fake B');
    SourceRegistry.instance.register(sourceA);
    SourceRegistry.instance.register(sourceB);
    addTearDown(() async => await SourceRegistry.instance.disposeAll());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(_FakePlayer()),
        ],
        child: const MaterialApp(
          home: SearchPage(
            showNowPlayingOverlay: false,
            showInPageSearchBar: true,
          ),
        ),
      ),
    );

    // Доступ к реальному контроллеру поиска через контейнер провайдеров.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchPage)),
    );
    final controller = container.read(searchProvider.notifier);

    // Заводим состояние «выбран источник, результатов 0»: ищем в источнике,
    // который всегда возвращает пустой список.
    controller.setSourceId('fake_a');
    await controller.search('nothing matches');
    // В testWidgets нельзя `await Future.delayed` в теле теста (таймер в
    // FakeAsync-зоне продвигается только через tester.pump), поэтому
    // просто рисуем следующий кадр, чтобы чипы отрисовались.
    await tester.pump();

    expect(container.read(searchProvider).results, isEmpty);
    expect(container.read(searchProvider).loading, false);
    expect(container.read(searchProvider).sourceId, 'fake_a');

    // 1) Чипы фильтров видны, даже несмотря на 0 результатов по источнику.
    expect(
      find.byKey(const ValueKey<String>('search-filter-fake_a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-filter-fake_b')),
      findsOneWidget,
    );

    // 2) Тап по активному чипу возвращает на «все источники» (kAllSourcesId).
    await tester.tap(
      find.byKey(const ValueKey<String>('search-filter-fake_a')),
    );
    await tester.pump();
    expect(container.read(searchProvider).sourceId, search.kAllSourcesId);

    // После сброса фильтра чипы остаются видимыми.
    expect(
      find.byKey(const ValueKey<String>('search-filter-fake_a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-filter-fake_b')),
      findsOneWidget,
    );
  });
}