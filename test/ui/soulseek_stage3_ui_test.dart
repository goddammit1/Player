// Widget-тесты Этапа 3 серии 02 (UI):
//   - CACHE-UI-01: кликабельный кэш-лист Soulseek (тап → setQueue из
//     trackFromCacheEntry, long-press → track settings sheet, incomplete
//     плитки пассивны);
//   - PLAYER-DL-01: source-aware тайл Download (native cache hit → «Cached»,
//     prefetch по тапу без dio-двойной загрузки, прогресс/завершение из
//     transferEvents, сброс после failed, не-Soulseek путь не тронут);
//   - QUALITY-01: детали трека показывают точный битрейт либо метку
//     качества («FLAC 24/96»), «unavailable» только при полном отсутствии
//     данных.
//
// Подмены (паттерны soulseek_source_test.dart / playlist_cache_menu_test.dart):
//   - SoulseekSource с DI fake-каналом (SoulseekChannel) регистрируется в
//     SourceRegistry — нативные MethodChannel/EventChannel не задействованы;
//   - playerServiceProvider → _FakePlayer (animatedPaletteProvider слушает
//     mediaItem-поток плеера);
//   - YoutubeCache audio dir → temp-каталог (не-Soulseek ветка проверки кэша);
//   - ArtworkHelper.disableDbReadsForTesting (нет path_provider в тестах).
//
// pumpAndSettle используется аккуратно: после тапов, порождающих SnackBar,
// таймеры выхолаживаются явным pump(Duration(seconds: 3)).

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_source.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/ui/widgets/artwork.dart';
import 'package:player/ui/widgets/soulseek_cache_sheet.dart';
import 'package:player/ui/widgets/track_details_sheet.dart';
import 'package:player/ui/widgets/track_settings_sheet.dart';

import '../setup/test_harness.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Fakes
// ═══════════════════════════════════════════════════════════════════════════

/// Fake SoulseekChannel (паттерн soulseek_source_test.dart).
class _TestChannel implements SoulseekChannel {
  @override
  bool isAvailable = true;

  List<SoulseekCacheEntry> cacheEntries = const [];
  SoulseekCacheEntry? cacheEntry;
  SoulseekTransferInfo? transferInfo;
  final List<Map<String, dynamic>> startDownloadCalls = [];

  final StreamController<SoulseekTransferEvent> _transferController =
      StreamController<SoulseekTransferEvent>.broadcast();

  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int idleTimeoutMs,
    required int responseLimit,
    required int fileLimit,
    required SoulseekSearchFilters filters,
  }) async => const [];

  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async =>
      cacheEntry;

  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async => cacheEntries;

  @override
  Future<SoulseekDownloadResult> startDownload({
    required String downloadId,
    required String peerUsername,
    required String remoteFilename,
    required int sizeBytes,
    required String cacheKey,
    required String fileExtension,
    String? title,
    String? artist,
    int? durationSeconds,
  }) async {
    startDownloadCalls.add({
      'downloadId': downloadId,
      'peerUsername': peerUsername,
      'remoteFilename': remoteFilename,
      'sizeBytes': sizeBytes,
      'cacheKey': cacheKey,
      'fileExtension': fileExtension,
    });
    return SoulseekDownloadResult(
      downloadId: downloadId,
      result: downloadId,
      cacheHit: false,
    );
  }

  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async =>
      transferInfo;

  @override
  Stream<SoulseekTransferEvent> get transferEvents =>
      _transferController.stream;

  void emitTransfer(SoulseekTransferInfo info) {
    _transferController.add(SoulseekTransferEvent(info));
  }

  void close() => _transferController.close();
}

/// Минимальный фейковый плеер (паттерн playlist_cache_menu_test.dart) с
/// записью вызовов setQueue.
class _FakePlayer implements PlayerServiceInterface {
  final List<(List<Track>, int)> setQueueCalls = [];

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
      throw UnimplementedError('not used in stage 3 ui tests');

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
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    setQueueCalls.add((List.of(tracks), startIndex));
  }

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

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

SoulseekCacheEntry _entry(
  String cacheKey,
  String title, {
  bool complete = true,
  String extension = 'flac',
}) {
  return SoulseekCacheEntry(
    cacheKey: cacheKey,
    localPath: '/data/cache/$cacheKey.$extension',
    sizeBytes: 1000,
    complete: complete,
    pinned: false,
    title: title,
    artist: 'Artist',
    durationSeconds: 180,
    extension: extension,
  );
}

/// Soulseek-трек с полным extra (как из поиска) — для Download-тайла.
Track _soulseekTrack({String cacheKey = 'ck1'}) {
  return Track(
    id: 'res_1',
    sourceId: 'soulseek',
    title: 'Soul Track',
    artist: 'Peer Artist',
    duration: const Duration(seconds: 200),
    qualityLabel: 'FLAC 24/96',
    extra: {
      'cacheKey': cacheKey,
      'peerUsername': 'peer1',
      'remoteFilename': 'Music/Soul Track.flac',
      'sizeBytes': 51000000,
      'extension': 'flac',
    },
  );
}

/// Хост-виджет: кнопка открывает тестируемую шторку поверх корневой
/// страницы (контекст с Navigator'ом).
Widget _host(Future<void> Function(BuildContext) opener, _FakePlayer player) {
  return ProviderScope(
    overrides: [playerServiceProvider.overrideWithValue(player)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => opener(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════════════

void main() {
  TestHarness.ensureInitialized();

  late _TestChannel channel;
  late SoulseekSource source;
  late _FakePlayer player;
  late Directory tempDir;

  // Кэш-шторка читает записи напрямую через SoulseekPlatformChannel
  // (P1-каскад: источник истины — нативная БД). Мокаем MethodChannel,
  // чтобы getCacheEntries возвращал те же записи, что и DI-канал, —
  // иначе real-канал кидает MissingPluginException, а шторка крутит
  // indeterminate-спиннер бесконечно (pumpAndSettle timeout).
  const methodsChannel = MethodChannel('soulseek/methods');

  Map<String, dynamic> entryToMap(SoulseekCacheEntry e) => {
        'cacheKey': e.cacheKey,
        'localPath': e.localPath,
        'sizeBytes': e.sizeBytes,
        'complete': e.complete,
        'pinned': e.pinned,
        'title': e.title,
        'artist': e.artist,
        'durationSeconds': e.durationSeconds,
        'extension': e.extension,
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ArtworkHelper.disableDbReadsForTesting = true;

    channel = _TestChannel();
    source = SoulseekSource(channel: channel);
    SourceRegistry.instance.register(source);

    player = _FakePlayer();

    tempDir = Directory.systemTemp.createTempSync('soulseek_stage3_ui_');
    YoutubeCache.instance.setAudioDirForTesting(tempDir);

    // animatedPaletteProvider → appThemeModeProvider читают настройки из
    // AppDatabase; без testDbPath он лезет в path_provider (в тестах
    // плагина нет → MissingPluginException). Подключаем БД к temp-каталогу.
    await TestHarness.setUpDb();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, (call) async {
      switch (call.method) {
        case 'getCacheEntries':
          return channel.cacheEntries.map(entryToMap).toList();
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, null);
    ArtworkHelper.disableDbReadsForTesting = false;
    YoutubeCache.instance.setAudioDirForTesting(null);
    await SourceRegistry.instance.disposeAll();
    channel.close();
    await TestHarness.tearDownDb();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ── CACHE-UI-01 ────────────────────────────────────────────────────────

  group('CACHE-UI-01: кликабельный кэш-лист', () {
    testWidgets('тап по complete-плитке вызывает setQueue с Track.extra.cacheKey',
        (tester) async {
      channel.cacheEntries = [
        _entry('ck1', 'Title A'),
        _entry('ck2', 'Title B'),
        _entry('ck3', 'Broken', complete: false),
      ];

      await tester.pumpWidget(_host(
        (ctx) => showSoulseekCacheSheet(ctx),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Title A'), findsOneWidget);
      expect(find.text('incomplete'), findsOneWidget);

      await tester.tap(find.text('Title B'));
      await tester.pumpAndSettle();

      // Очередь = все complete-треки (2 из 3), старт со второго.
      expect(player.setQueueCalls, hasLength(1));
      final (tracks, startIndex) = player.setQueueCalls.single;
      expect(tracks, hasLength(2));
      expect(startIndex, 1);
      // Track построен через trackFromCacheEntry: cacheKey в extra —
      // мгновенный cache hit в resolveStreamUrl.
      expect(tracks[0].extra['cacheKey'], 'ck1');
      expect(tracks[1].extra['cacheKey'], 'ck2');
      expect(tracks[0].sourceId, SoulseekSource.sourceId);
    });

    testWidgets('тап по incomplete-плитке ничего не играет', (tester) async {
      channel.cacheEntries = [_entry('ck3', 'Broken', complete: false)];

      await tester.pumpWidget(_host(
        (ctx) => showSoulseekCacheSheet(ctx),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Broken'));
      await tester.pumpAndSettle();

      expect(player.setQueueCalls, isEmpty);
    });

    testWidgets('long-press открывает track settings sheet', (tester) async {
      channel.cacheEntries = [_entry('ck1', 'Title A')];

      await tester.pumpWidget(_host(
        (ctx) => showSoulseekCacheSheet(ctx),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Title A'));
      await tester.pumpAndSettle();

      // Settings sheet с действиями как у плиток поиска.
      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
    });

    testWidgets(
        'ART-CACHE-01: long-press sheet подхватывает обложку из mem-кэша '
        '(трек играл в этой сессии)', (tester) async {
      final ap = ArtworkProvider.instance;
      ap.clearMemCache();
      addTearDown(ap.clearMemCache);

      channel.cacheEntries = [_entry('ck1', 'Title A')];
      // Трек уже играл: findArtwork при воспроизведении положил найденный
      // URL в mem-кэш — эмулируем это тестовым хуком (сеть не трогаем).
      ap.cacheArtworkForTesting('Artist', 'Title A', 'https://img/cov.jpg');

      await tester.pumpWidget(_host(
        (ctx) => showSoulseekCacheSheet(ctx),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Title A'));
      await tester.pumpAndSettle();

      // trackFromCacheEntry не несёт artworkUrl; sheet обязан обогатить
      // трек синхронно из mem-кэша — Artwork получает URL вместо null.
      final artworks =
          tester.widgetList<Artwork>(find.byType(Artwork)).toList();
      expect(
        artworks.any((a) => a.url == 'https://img/cov.jpg'),
        isTrue,
        reason: 'settings sheet должен передать Artwork URL из mem-кэша',
      );
    });
  });

  // ── PLAYER-DL-01 ───────────────────────────────────────────────────────

  group('PLAYER-DL-01: source-aware тайл Download', () {
    testWidgets('native cache hit → «Cached»', (tester) async {
      channel.cacheEntry = _entry('ck1', 'Soul Track');

      await tester.pumpWidget(_host(
        (ctx) => showTrackSettingsSheet(ctx, track: _soulseekTrack()),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Cached'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
    });

    testWidgets('тап Download → prefetch (native startDownload), прогресс и Cached из transferEvents',
        (tester) async {
      // Не в кэше, активного трансфера нет.
      channel.cacheEntry = null;
      channel.transferInfo = null;

      await tester.pumpWidget(_host(
        (ctx) => showTrackSettingsSheet(ctx, track: _soulseekTrack()),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);

      await tester.tap(find.text('Download'));
      await tester.pump();

      // Prefetch запустил нативную загрузку (dedupe downloadId = dl_ck1).
      expect(channel.startDownloadCalls, hasLength(1));
      expect(channel.startDownloadCalls.single['downloadId'], 'dl_ck1');

      // Прогресс из transferEvents → «Downloading… N%».
      channel.emitTransfer(const SoulseekTransferInfo(
        downloadId: 'dl_ck1',
        state: SoulseekTransferState.downloading,
        bytesReceived: 25500000,
        totalBytes: 51000000,
      ));
      await tester.pump();
      expect(find.text('Downloading… 50%'), findsOneWidget);

      // Завершение → «Cached».
      channel.emitTransfer(const SoulseekTransferInfo(
        downloadId: 'dl_ck1',
        state: SoulseekTransferState.completed,
        bytesReceived: 51000000,
        totalBytes: 51000000,
        localPath: '/data/cache/ck1.flac',
      ));
      await tester.pump();
      expect(find.text('Cached'), findsOneWidget);
    });

    testWidgets('failed-событие сбрасывает состояние и показывает ошибку',
        (tester) async {
      channel.cacheEntry = null;
      channel.transferInfo = null;

      await tester.pumpWidget(_host(
        (ctx) => showTrackSettingsSheet(ctx, track: _soulseekTrack()),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Download'));
      await tester.pump();

      channel.emitTransfer(const SoulseekTransferInfo(
        downloadId: 'dl_ck1',
        state: SoulseekTransferState.failed,
        errorCode: 'PEER_DISCONNECTED',
        message: 'peer gone',
      ));
      await tester.pump();

      expect(find.textContaining('Download failed'), findsOneWidget);
      // Выхолаживаем SnackBar-таймер (иначе pending timer уронит тест).
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // Кнопка вернулась в исходное состояние.
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('не-Soulseek трек: YoutubeCache-путь без native startDownload',
        (tester) async {
      const track = Track(
        id: 'mz_1',
        sourceId: 'muzmo',
        title: 'Web Track',
        artist: 'Artist',
      );

      await tester.pumpWidget(_host(
        (ctx) => showTrackSettingsSheet(ctx, track: track),
        player,
      ));
      // Запускаем построение sheet и файловую проверку в реальной async-зоне.
      await tester.runAsync(() async {
        await tester.tap(find.text('open'));
        await tester.pump();
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.text('Download').evaluate().isNotEmpty) break;
        }
      });
      await tester.pumpAndSettle();

      // YoutubeCache пуст → «Download», soulseek-канал не тронут.
      expect(find.text('Download'), findsOneWidget);
      expect(channel.startDownloadCalls, isEmpty);
    });
  });

  // ── QUALITY-01 ─────────────────────────────────────────────────────────

  group('QUALITY-01: качество в деталях трека', () {
    testWidgets('qualityScore показывается как «N kbps»', (tester) async {
      const track = Track(
        id: 'mz_1',
        sourceId: 'muzmo',
        title: 'Web Track',
        artist: 'Artist',
        qualityScore: 320,
      );

      await tester.pumpWidget(_host(
        (ctx) => showTrackDetailsSheet(ctx, track),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('320 kbps'), findsOneWidget);
      expect(find.text('unavailable'), findsNothing);
    });

    testWidgets('без qualityScore → qualityLabel «FLAC 24/96» вместо unavailable',
        (tester) async {
      final track = _soulseekTrack();

      await tester.pumpWidget(_host(
        (ctx) => showTrackDetailsSheet(ctx, track),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('FLAC 24/96'), findsOneWidget);
      expect(find.text('unavailable'), findsNothing);
    });

    testWidgets('кэш-трек: метка из extension (extra), без точного битрейта',
        (tester) async {
      final track = source.trackFromCacheEntry(_entry('ck9', 'Cache Track'));

      await tester.pumpWidget(_host(
        (ctx) => showTrackDetailsSheet(ctx, track),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // trackFromCacheEntry строит метку из extension («FLAC»).
      expect(find.text('FLAC'), findsOneWidget);
      expect(find.text('unavailable'), findsNothing);
    });

    testWidgets('нет данных качества → честное «unavailable»', (tester) async {
      const track = Track(
        id: 'mz_2',
        sourceId: 'muzmo',
        title: 'No Quality',
        artist: 'Artist',
      );

      await tester.pumpWidget(_host(
        (ctx) => showTrackDetailsSheet(ctx, track),
        player,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('unavailable'), findsOneWidget);
    });
  });
}
