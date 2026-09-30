// Regression-тест бага «первое нажатие Connect не подключает — нужно
// нажать второй раз».
//
// Корневые причины (исправлены):
//   1. soulseek_settings_page.dart: при первом bind'е сервиса натив шлёт
//      snapshot DISCONNECTED (клиента ещё нет). Страница трактовала его как
//      терминальное событие — сбрасывала _connecting, кнопка снова
//      становилась «Connect», статус «Disconnected», хотя connect ещё шёл.
//   2. SoulseekPlugin.kt: команда ставилась в очередь через mainHandler.post
//      и могла попасть туда ПОСЛЕ onServiceConnected — зависала до таймаута.
//   3. SoulseekBridge.cs: SocketException первого коннекта приходит
//      обёрнутой в SoulseekClientException — не считалась retryable, и
//      retry-цикл страницы не срабатывал.
//
// Здесь проверяется пункт 1 (Dart); 2 и 3 — нативные.

import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/player_service.dart' show SleepTimerMode;
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/soulseek_settings_page.dart';

import '../setup/test_harness.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Fakes
// ═══════════════════════════════════════════════════════════════════════════

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
      throw UnimplementedError('not used in soulseek connect tests');

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

/// Эмулирует push-событие соединения из натива (EventChannel).
Future<void> pushConnectionEvent(String state) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'soulseek/events',
    const StandardMethodCodec().encodeSuccessEnvelope(
      jsonEncode({'eventType': 'connection', 'state': state, 'message': null}),
    ),
    (_) {},
  );
}

void main() {
  TestHarness.ensureInitialized();

  late Completer<Map<String, Object?>> connectReply;
  // Если задан — connect после ответа бросает эту ошибку (throw внутри
  // handler'а: ошибка Completer'а из другой зоны считалась бы необработанной).
  late PlatformException? connectError;
  late int connectCalls;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'soulseek_username': 'user',
      'soulseek_password': 'pass',
    });

    await TestHarness.setUpDb();

    connectReply = Completer<Map<String, Object?>>();
    connectError = null;
    connectCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, (call) async {
      switch (call.method) {
        case 'startService':
          return true;
        case 'connect':
          connectCalls++;
          final reply = await connectReply.future;
          if (connectError != null) throw connectError!;
          return reply;
        case 'getConnectionState':
          return 'UNKNOWN';
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventsChannel, (call) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventsChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await TestHarness.tearDownDb();
  });

  Future<void> openPageAndTapConnect(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    expect(connectCalls, 1);
    expect(find.text('Connect'), findsNothing);
  }

  testWidgets(
      'snapshot DISCONNECTED при первом bind не сбрасывает «Connecting…» — '
      'первое нажатие доводит подключение до конца', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);

        // onServiceConnected → snapshot состояния ещё не созданного клиента.
        await pushConnectionEvent('DISCONNECTED');
        await tester.pump();

        // Раньше здесь кнопка снова становилась «Connect», статус —
        // «Disconnected», и пользователь жал второй раз.
        expect(find.text('Connect'), findsNothing);
        expect(find.text('Disconnected'), findsNothing);

        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Connect'), findsOneWidget);
        expect(connectCalls, 1);
        expect(find.textContaining("couldn't be saved"), findsNothing);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'провал команды после промежуточного CONNECTING не оставляет '
      'кнопку залипшей в «Connecting…»', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);

        await pushConnectionEvent('CONNECTING');
        await pushConnectionEvent('DISCONNECTED');
        await tester.pump();

        connectError = PlatformException(
          code: 'LoginRejectedException',
          message: 'rejected',
          details: {'retryable': false},
        );
        connectReply.complete(const {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Connection failed'), findsOneWidget);
        expect(find.text('Connect'), findsOneWidget);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Сбой secure storage у пользователя 3.0.0-beta (NPE в плагине) раньше
  // обрывал Connect ещё до вызова натива — Soulseek был недоступен совсем.
  testWidgets(
      'сбой записи в secure storage не блокирует подключение — '
      'пользователь только предупреждается', (tester) async {
    // Мок плагина пишет прямо в эту Map: неизменяемая → write() бросает,
    // чтение (предзаполнение полей) работает.
    FlutterSecureStorage.setMockInitialValues(Map.unmodifiable({
      'soulseek_username': 'user',
      'soulseek_password': 'pass',
    }));
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);

        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Connected'), findsOneWidget);
        expect(find.textContaining("couldn't be saved"), findsOneWidget);
        expect(connectCalls, 1);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
