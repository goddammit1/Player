// Regression-тест бага «таймаут поиска Soulseek невозможно изменить»:
// при перезаходе на страницу настроек поле всегда показывало 15 секунд.
//
// Корневые разрывы (исправлены в soulseek_settings_page.dart):
//   1. _NumericField создавал TextEditingController один раз в initState
//      из дефолта (15) и не имел didUpdateWidget — после асинхронного
//      loadAll() → setState поле не получало сохранённое в БД значение.
//   2. dispose отменял 500-мс debounce-таймер вместо коммита — правка,
//      сделанная < 500 мс до ухода со страницы, терялась.
//   3. _updateSearchTimeout не применял таймаут к SoulseekSource (ленивая
//      загрузка в источнике одноразовая) — источник жил со старым значением.
//
// Проверяется полная цепочка: поле ← БД при открытии, поле → БД при правке,
// поле → SoulseekSource, коммит при dispose до срабатывания debounce.
//
// Подмены (паттерны soulseek_stage3_ui_test.dart / settings_subpages_test.dart):
//   - debugDefaultTargetPlatformOverride = android (иначе страница показывает
//     заглушку «Soulseek is only available on Android»);
//   - SoulseekSource с DI fake-каналом регистрируется в SourceRegistry;
//   - playerServiceProvider → _FakePlayer (animatedPaletteProvider слушает
//     mediaItem-поток плеера);
//   - MethodChannel/EventChannel soulseek/* замоканы (connectionEvents,
//     getConnectionState).

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/soulseek_settings_repository.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_source.dart';
import 'package:player/sources/source_registry.dart';
import 'package:player/ui/pages/soulseek_settings_page.dart';

import '../setup/test_harness.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Fakes
// ═══════════════════════════════════════════════════════════════════════════

/// Fake SoulseekChannel: доступен, поиск пишет timeoutMs в lastTimeoutMs.
class _FakeChannel implements SoulseekChannel {
  @override
  bool get isAvailable => true;

  int? lastTimeoutMs;

  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int idleTimeoutMs,
    required int responseLimit,
    required int fileLimit,
    required SoulseekSearchFilters filters,
  }) async {
    lastTimeoutMs = timeoutMs;
    return const [];
  }

  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async => null;

  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async => const [];

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
  }) => throw UnimplementedError();

  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async => null;

  @override
  Stream<SoulseekTransferEvent> get transferEvents =>
      const Stream<SoulseekTransferEvent>.empty();
}

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
      throw UnimplementedError('not used in soulseek timeout tests');

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

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

const methodsChannel = MethodChannel('soulseek/methods');
const eventsChannel = MethodChannel('soulseek/events');

Widget wrap(Widget home) {
  return ProviderScope(
    overrides: [playerServiceProvider.overrideWithValue(_FakePlayer())],
    child: MaterialApp(home: home),
  );
}

/// TextField «Search timeout (seconds)» — ищем по иконке timer_outlined.
Finder findTimeoutField() => find.ancestor(
      of: find.byIcon(Icons.timer_outlined),
      matching: find.byType(TextField),
    );

String timeoutFieldText() {
  final field = testerInstance.widget<TextField>(findTimeoutField());
  return field.controller!.text;
}

// Доступ к текущему WidgetTester из timeoutFieldText (устанавливается
// в каждом тесте) — тестам удобнее читать текст контроллера напрямую.
late WidgetTester testerInstance;

void main() {
  TestHarness.ensureInitialized();

  late _FakeChannel channel;
  late SoulseekSource source;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});

    channel = _FakeChannel();
    source = SoulseekSource(channel: channel);
    SourceRegistry.instance.register(source);

    await TestHarness.setUpDb();

    // Страница при открытии подписывается на connectionEvents (EventChannel)
    // и запрашивает состояние (getConnectionState). Мокаем обе channels.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventsChannel, (call) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventsChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await SourceRegistry.instance.disposeAll();
    await TestHarness.tearDownDb();
  });

  group('Search timeout: сохранение и восстановление (регрессия «всегда 15»)', () {
    testWidgets(
        'поле показывает значение из БД после асинхронной загрузки, '
        'правка сохраняется в БД и применяется к SoulseekSource',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
      await tester.runAsync(() async {
      testerInstance = tester;

      // Сидим сохранённое ранее значение (не дефолт 15).
      await SoulseekSettingsRepository.instance.setSearchTimeoutSec(45);

      await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Разрыв №1: без didUpdateWidget поле навсегда оставалось «15» —
      // значение из БД (45) не отображалось после асинхронного loadAll.
      expect(timeoutFieldText(), '45');

      // Меняем значение в поле: 30.
      await tester.enterText(findTimeoutField(), '30');
      // Debounce 500 мс → коммит (onChanged → _updateSearchTimeout).
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Значение ушло в БД (не 15!).
      final settings = await SoulseekSettingsRepository.instance.loadAll();
      expect(settings.searchTimeoutSec, 30);

      // Разрыв №3: SoulseekSource получает изменённый таймаут сразу.
      expect(source.searchTimeoutMs, 30000);
      });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('повторное открытие страницы показывает сохранённое значение',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
      await tester.runAsync(() async {
      testerInstance = tester;

      await SoulseekSettingsRepository.instance.setSearchTimeoutSec(77);

      // Первое открытие.
      await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(timeoutFieldText(), '77');

      // «Перезаход» на страницу: новый instance state → initState с
      // дефолтом 15 → асинхронная загрузка → поле обязано показать 77.
      await tester.pumpWidget(wrap(const Scaffold(body: SizedBox())));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(timeoutFieldText(), '77');
      expect(
        (await SoulseekSettingsRepository.instance.loadAll()).searchTimeoutSec,
        77,
      );
      });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'правка коммитится при закрытии страницы до срабатывания debounce '
        '(разрыв №2: dispose раньше отменял таймер)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
      await tester.runAsync(() async {
      testerInstance = tester;

      // Хост с кнопкой: страница пушился как маршрут — есть кнопка «назад».
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerServiceProvider.overrideWithValue(_FakePlayer()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SoulseekSettingsPage(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(timeoutFieldText(), '10'); // дефолт: БД пуста

      // Правка < 500 мс до закрытия — debounce ещё не сработал.
      await tester.enterText(findTimeoutField(), '25');
      await tester.pump(const Duration(milliseconds: 100));

      // Уходим со страницы: dispose обязан закоммитить pending-правку.
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final settings = await SoulseekSettingsRepository.instance.loadAll();
      expect(settings.searchTimeoutSec, 25);
      expect(source.searchTimeoutMs, 25000);
      });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
