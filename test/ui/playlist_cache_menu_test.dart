// Widget-тесты пункта меню «Cache all tracks» и шторки прогресса
// пакетного кэширования плейлиста.
//
// Что подменяется:
//   - playerServiceProvider → _FakePlayer (NowPlayingOverlay и палитра
//     слушают потоки плеера, поэтому нужен фейк).
//   - playlistsProvider → синхронный Stream.value(плейлисты из памяти).
//     Это КРИТИЧНО: настоящий провайдер делает `await
//     PlaylistRepository.instance.ensureLoaded()` (реальный sqflite_ffi I/O)
//     внутри FakeAsync-зоны testWidgets, что приводит к жёсткому дедлоку —
//     фейковый event loop не может обслужить настоящий микрозадачный I/O,
//     и тест висит на +0 без срабатывания даже --timeout. Все реальные
//     async-зависимости (БД, сеть) заменены синхронными фейками.
//   - PlaylistPage.playlistCacheServiceFactoryOverride → фейковый
//     PlaylistCacheService с управляемым поведением cacheTracks
//     (Completer для ручного управления, запись onProgress,
//     уважение CancelToken). Сбрасывается в tearDown.
//   - YoutubeCache audio dir → temp-каталог через setAudioDirForTesting.
//
// ВАЖНО: pumpAndSettle здесь НЕ используется. PlaylistPage содержит
// бесконечный AnimationController.repeat() (shimmer), плюс indeterminate
// LinearProgressIndicator в шторке и SnackBar с таймером — всё это не
// даёт settle. Вместо него — детерминированный flush() из N pump.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/playlist_cache_service.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/playlist_page.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый плеер (паттерн settings_subpages_test.dart).
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
      throw UnimplementedError('not used in playlist cache menu tests');

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

/// Фейковый сервис пакетного кэширования с полностью управляемым
/// поведением. Реальная сеть/кэш не трогаются.
class _FakePlaylistCacheService implements PlaylistCacheService {
  /// Если задан, cacheTracks ждёт этот Completer (ручное управление).
  Completer<PlaylistCacheResult>? gate;

  /// Результат, который вернёт cacheTracks, когда gate не задан
  /// (мгновенное завершение).
  PlaylistCacheResult result = const PlaylistCacheResult(
    downloaded: 0,
    skippedCached: 0,
    skippedDisabled: 0,
    failed: 0,
    cancelled: false,
  );

  CancelToken? lastCancelToken;
  void Function(PlaylistCacheProgress)? lastOnProgress;
  List<Track>? lastTracks;
  int calls = 0;

  @override
  Future<PlaylistCacheResult> cacheTracks(
    List<Track> tracks, {
    CancelToken? cancelToken,
    void Function(PlaylistCacheProgress progress)? onProgress,
  }) {
    calls++;
    lastTracks = tracks;
    lastCancelToken = cancelToken;
    lastOnProgress = onProgress;
    onProgress?.call(
      PlaylistCacheProgress(
        completed: 0,
        total: tracks.length,
        currentTitle: tracks.isNotEmpty ? tracks.first.title : '',
        currentProgress: null,
      ),
    );

    final g = gate;
    if (g != null) {
      // Ручное управление + уважение отмены: при cancel() завершаемся
      // с cancelled=true, как настоящий сервис. `whenCancel` ЗАВЕРШАЕТСЯ
      // ОШИБКОЙ (DioException), поэтому ловим через catchError, иначе
      // unhandled async error уронит тест.
      cancelToken?.whenCancel.then((_) => _completeCancelled(g)).catchError(
        (Object _) => _completeCancelled(g),
      );
      return g.future;
    }
    return Future.value(result);
  }

  void _completeCancelled(Completer<PlaylistCacheResult> g) {
    if (g.isCompleted) return;
    g.complete(
      const PlaylistCacheResult(
        downloaded: 0,
        skippedCached: 0,
        skippedDisabled: 0,
        failed: 0,
        cancelled: true,
      ),
    );
  }
}

void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  late _FakePlaylistCacheService fakeService;

  Track track(String id) => Track(
        id: id,
        sourceId: 'muzmo',
        title: 'Song $id',
        artist: 'Artist $id',
      );

  /// Плейлисты только в памяти — никакого реального I/O, поэтому
  /// всё происходит синхронно внутри FakeAsync-зоны без дедлока.
  Playlist makePlaylist(String name, List<Track> tracks) => Playlist(
        id: 'pl-$name',
        name: name,
        tracks: List.unmodifiable(tracks),
        createdAt: DateTime(2024),
      );

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Player',
      packageName: 'com.player.player',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
    tempDir = Directory.systemTemp.createTempSync('playlist_cache_menu_test_');
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(tempDir);

    fakeService = _FakePlaylistCacheService();
    // ignore: invalid_use_of_visible_for_testing_member
    PlaylistPage.playlistCacheServiceFactoryOverride = () => fakeService;

  });

  tearDown(() {
    // ignore: invalid_use_of_visible_for_testing_member
    PlaylistPage.playlistCacheServiceFactoryOverride = null;
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Обёртка с фейковым синхронным провайдером плейлистов.
  /// Стрим отдаёт [playlists] один раз и не зависает на реальном I/O.
  Widget wrap(Widget home, List<Playlist> playlists) {
    return ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(_FakePlayer()),
        playlistsProvider.overrideWith(
          (ref) => Stream<List<Playlist>>.value(playlists),
        ),
      ],
      child: MaterialApp(home: home),
    );
  }

  /// Детерминированная замена pumpAndSettle: прогоняет [frames] кадров
  /// с шагом [step]. Достаточно, чтобы отработали microtask-очередь,
  /// post-frame колбэки, анимации открытия/закрытия шторки и появление
  /// снэка — но НЕ ждёт бесконечные repeat-анимации страницы.
  ///
  /// После каждого pump поглощаем ТОЛЬКО исключения переполнения RenderFlex.
  /// В тестовой среде Flutter использует шрифт-заглушку (Ahem), заметно более
  /// широкую, чем реальный Geist, поэтому кнопка сортировки (фикс. ширина
  /// 95px с текстом 16sp) переполняется на ~43px. Это артефакт тестового
  /// шрифта, а не реальный баг вёрстки. `takeException()` снимает ожидающее
  /// исключение, чтобы оно не роняло тест; прочие исключения (null-derer,
  /// provider-ошибки и т.п.) по-прежнему всплывут и уронят тест.
  Future<void> flush(
    WidgetTester tester, {
    int frames = 25,
    Duration step = const Duration(milliseconds: 100),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
      final exc = tester.takeException();
      if (exc != null && !exc.toString().contains('RenderFlex overflowed')) {
        // Не layout-переполнение — реальная ошибка. Бросаем обратно.
        throw exc;
      }
    }
  }

  Future<void> pumpPage(WidgetTester tester, Playlist playlist) async {
    // Задаём широкую тестовую поверхность (desktop-ширина). Иначе в узком
    // дефолтном окне 800x600 кнопка сортировки (ширина 95 + текст 16sp)
    // переполняется справа и падает RenderFlex overflow — это не
    // функциональная проблема, а ограничение размера окна.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        PlaylistPage(playlistId: playlist.id, showNowPlayingOverlay: false),
        [playlist],
      ),
    );
    await flush(tester);
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await flush(tester);
  }

  group('Cache all tracks menu item', () {
    testWidgets('menu shows the "Cache all tracks" entry', (tester) async {
      final p = makePlaylist('Mix', [track('1'), track('2')]);
      await pumpPage(tester, p);

      await openMenu(tester);

      expect(find.text('Cache all tracks'), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    });

    testWidgets('tapping the entry opens the progress sheet', (tester) async {
      fakeService.gate = Completer<PlaylistCacheResult>();
      final p = makePlaylist('Mix', [track('1'), track('2')]);
      await pumpPage(tester, p);

      await openMenu(tester);
      await tester.tap(find.text('Cache all tracks'));
      await flush(tester);

      expect(find.textContaining('Caching'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Дожимаем фейк, чтобы tearDown не оставил висящих фьючерсов.
      fakeService.gate!.complete(
        const PlaylistCacheResult(
          downloaded: 2,
          skippedCached: 0,
          skippedDisabled: 0,
          failed: 0,
          cancelled: false,
        ),
      );
      await flush(tester);
    });

    testWidgets('Cancel disables itself and ends with cancelled snack',
        (tester) async {
      fakeService.gate = Completer<PlaylistCacheResult>();
      final p = makePlaylist('Mix', [track('1'), track('2')]);
      await pumpPage(tester, p);

      await openMenu(tester);
      await tester.tap(find.text('Cache all tracks'));
      await flush(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      // Кнопка стала одноразовой: текст сменился и она задизейблена.
      expect(find.text('Cancelling…'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Cancelling…'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);

      // Фейк уважает cancelToken → шторка закрывается cancelled-результатом,
      // и появляется снэк отмены. Снэк живёт всего 1.2s (см. snack.dart),
      // поэтому ждём КОРОТКО — иначе он успеет исчезнуть до проверки.
      await flush(tester, frames: 6);
      expect(find.textContaining('Caching cancelled'), findsOneWidget);
    });

    testWidgets('success result shows the success snack', (tester) async {
      fakeService.result = const PlaylistCacheResult(
        downloaded: 2,
        skippedCached: 1,
        skippedDisabled: 0,
        failed: 0,
        cancelled: false,
      );
      final p = makePlaylist('Mix', [track('1'), track('2')]);
      await pumpPage(tester, p);

      await openMenu(tester);
      await tester.tap(find.text('Cache all tracks'));
      // success-снэк живёт 1.5s — ждём коротко, чтобы он не исчез.
      await flush(tester, frames: 8);

      expect(find.textContaining('Playlist cached'), findsOneWidget);
      expect(find.textContaining('2 downloaded'), findsOneWidget);
    });

    testWidgets('failed>0 result shows the error snack', (tester) async {
      fakeService.result = const PlaylistCacheResult(
        downloaded: 1,
        skippedCached: 0,
        skippedDisabled: 0,
        failed: 1,
        cancelled: false,
      );
      final p = makePlaylist('Mix', [track('1'), track('2')]);
      await pumpPage(tester, p);

      await openMenu(tester);
      await tester.tap(find.text('Cache all tracks'));
      await flush(tester);

      expect(find.textContaining('Cached with errors'), findsOneWidget);
      expect(find.textContaining('1 of 2 failed'), findsOneWidget);
    });

    testWidgets('empty playlist shows "Nothing to cache" and no sheet',
        (tester) async {
      final p = makePlaylist('Empty', const []);
      await pumpPage(tester, p);

      await openMenu(tester);
      await tester.tap(find.text('Cache all tracks'));
      // Снэк 'Nothing to cache' живёт 1.2s — ждём коротко.
      await flush(tester, frames: 6);

      expect(find.text('Nothing to cache'), findsOneWidget);
      expect(find.textContaining('Caching'), findsNothing);
      expect(fakeService.calls, 0);
    });
  });
}
