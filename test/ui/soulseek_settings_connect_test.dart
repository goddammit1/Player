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

import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/soulseek_credentials.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/soulseek_settings_page.dart';
import 'package:player/sources/soulseek_session_transfers.dart';
import 'package:player/ui/pages/downloads_page.dart';

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

  @override
  Stream<List<Track>> get trackQueueStream =>
      Stream<List<Track>>.value(trackQueue);

  @override
  Future<void> clearQueue() async {}
}

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

const methodsChannel = MethodChannel('soulseek/methods');
const eventsChannel = MethodChannel('soulseek/events');

Widget wrap(Widget home) {
  return ProviderScope(
    overrides: [
      playerServiceProvider.overrideWithValue(_FakePlayer()),
      // Страница вибрирует на тапах (HapticHelper читает этот провайдер):
      // без seeded ленивая загрузка из БД пишет state после dispose.
      vibrationEnabledProvider
          .overrideWith((ref) => VibrationNotifier.seeded(false)),
    ],
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
  late int disconnectCalls;
  late List<Map<String, Object?>> transfersReply;
  late List<String> retried;
  late int clearCalls;

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
    disconnectCalls = 0;
    transfersReply = const [];
    retried = [];
    clearCalls = 0;

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
        case 'disconnect':
          disconnectCalls++;
          return true;
        case 'getActiveTransfers':
          return transfersReply;
        case 'retryDownload':
          retried.add((call.arguments as Map)['downloadId'] as String);
          return true;
        case 'clearFinishedTransfers':
          clearCalls++;
          final removed = transfersReply.length;
          transfersReply = const [];
          return removed;
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

    final callsBefore = connectCalls;
    await tester.tap(find.text('Connect'));
    // До нативного connect — secure storage и startService: под нагрузкой
    // (полный прогон) фиксированных 100 мс бывает мало.
    for (var i = 0; i < 20 && connectCalls == callsBefore; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(connectCalls, callsBefore + 1);
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
        // После входа единственная кнопка статуса — Disconnect.
        expect(find.text('Disconnect'), findsOneWidget);
        expect(find.text('Connect'), findsNothing);
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
  // ═══════════════════════════════════════════════════════════════════════
  //  Редизайн: одна кнопка статуса, Advanced, лист загрузок
  // ═══════════════════════════════════════════════════════════════════════

  testWidgets(
      'Cancel во время подключения: строка статуса скрыта, поздний ответ '
      'connect не применяется и разрывается', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Connecting…'), findsOneWidget);

        // Без соединения строка статуса не показывается — только Connect.
        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(find.text('Connecting…'), findsNothing);
        expect(find.text('Disconnected'), findsNothing);
        expect(find.text('Connect'), findsOneWidget);

        // Натив всё-таки вошёл — страница не показывает «Connected»
        // и разрывает это соединение.
        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        expect(find.text('Connected'), findsNothing);
        expect(find.text('Connect'), findsOneWidget);
        expect(disconnectCalls, 2);
        expect(find.textContaining('Connection failed'), findsNothing);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'после входа логин в статусе, Save появляется только после правки',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('as user'), findsOneWidget);
        // Поля остаются (смена аккаунта); без правок кнопки сохранения нет.
        expect(find.text('Save'), findsNothing);
        expect(find.text('Save and reconnect'), findsNothing);

        await tester.enterText(find.byType(TextField).at(1), 'other');
        await tester.pump(const Duration(milliseconds: 400));
        final save = tester.widget<InkWell>(
          find.ancestor(
            of: find.text('Save and reconnect'),
            matching: find.byType(InkWell),
          ),
        );
        expect(save.onTap, isNotNull);

        // Вернули прежний пароль — правок нет, кнопка снова скрыта.
        await tester.enterText(find.byType(TextField).at(1), 'pass');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Save and reconnect'), findsNothing);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Advanced свёрнут по умолчанию и раскрывается по тапу',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(find.text('Listener port'), findsNothing);
        expect(find.text('Clear account data'), findsNothing);

        // Свои слайдер и колесо подписаны для экранного диктора.
        final semantics = tester.ensureSemantics();
        await tester.pump();
        expect(find.bySemanticsLabel('Max file size'), findsOneWidget);
        expect(find.bySemanticsLabel('Parallel downloads'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Search timeout, seconds'),
          findsOneWidget,
        );
        semantics.dispose();

        await tester.tap(find.text('Show more'));
        await tester.pumpAndSettle();
        expect(find.text('Listener port'), findsOneWidget);
        expect(find.text('Clear account data'), findsOneWidget);
        expect(find.text('Show less'), findsOneWidget);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'Downloads: группы загрузок, формат из имени файла, упавшие прошлых '
      'сессий скрыты, Retry и Clear уходят в натив', (tester) async {
    transfersReply = [
      {
        'downloadId': 'dl_a',
        'state': 'DOWNLOADING',
        'bytesReceived': 50,
        'totalBytes': 100,
        'bytesPerSecond': 1024,
        'title': 'Song A',
        'artist': 'Artist A',
        'remoteFilename': r'music\Artist A\01 Song A.flac',
      },
      {
        'downloadId': 'dl_b',
        'state': 'FAILED',
        'message': 'Peer offline',
        'title': 'Song B',
        'artist': 'Artist B',
        'remoteFilename': 'music/Artist B/Song B.mp3',
      },
      // Упала в прошлом запуске (натив поднял из БД) — не показывается.
      {
        'downloadId': 'dl_c',
        'state': 'FAILED',
        'title': 'Song C',
        'remoteFilename': 'music/Artist C/Song C.mp3',
      },
      // Завершённая — уже в списке готовых треков, не в группах загрузок.
      {
        'downloadId': 'dl_d',
        'state': 'COMPLETED',
        'title': 'Song D',
        'remoteFilename': 'music/Artist D/Song D.mp3',
      },
    ];
    SoulseekSessionTransfers.instance.add('dl_b');
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(wrap(const DownloadsPage()));
        // Ответы getActiveTransfers и кэша приходят асинхронно.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Downloading'), findsOneWidget);
        expect(find.text('Failed'), findsOneWidget);
        expect(find.textContaining('FLAC · Artist A · 50%'), findsOneWidget);
        expect(find.textContaining('MP3 · Artist B · Failed'), findsOneWidget);
        expect(find.textContaining('Peer offline'), findsOneWidget);
        expect(find.text('Song C'), findsNothing);
        expect(find.text('Song D'), findsNothing);

        await tester.tap(find.byTooltip('Retry'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(retried, ['dl_b']);

        await tester.tap(find.text('Clear'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 100));
        expect(clearCalls, 1);
        expect(find.text('No downloads yet'), findsOneWidget);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets(
      'автопереподключение из натива (без команды): Cancel разрывает '
      'соединение', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(wrap(const SoulseekSettingsPage()));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        await pushConnectionEvent('RECONNECTING');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(find.text('Reconnecting…'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(disconnectCalls, 1);
        // Только snack «Disconnected» от обычного disconnect: без соединения
        // строка статуса скрыта.
        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('Reconnecting…'), findsNothing);
        expect(find.text('Connect'), findsOneWidget);
        expect(connectCalls, 0);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'Cancel и сразу Connect: отменённая команда не применяет итог и не '
      'рвёт новое подключение', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);

        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        expect(disconnectCalls, 1);

        await tester.tap(find.text('Connect'));
        for (var i = 0; i < 20 && connectCalls < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump();
        expect(connectCalls, 2);
        expect(find.text('Cancel'), findsOneWidget);

        // Обе нативные попытки возвращаются одним ответом.
        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Disconnect'), findsOneWidget);
        // Отменённая команда не разорвала новое соединение.
        expect(disconnectCalls, 1);
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'Save and reconnect с неверным паролем не затирает рабочие креды; '
      'новые сохраняются только после успешного входа', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(() async {
        await openPageAndTapConnect(tester);
        connectReply.complete({'username': 'user', 'state': 'CONNECTED'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        expect(find.text('Connected'), findsOneWidget);

        // Опечатка в пароле → кнопка предлагает переподключиться.
        // Кнопка появляется в группе через AnimatedSize — даём ей раскрыться,
        // иначе тап попадает мимо. Анимация стартует в кадре, где замечен
        // новый размер, поэтому сначала обычный кадр, потом время.
        await tester.enterText(find.byType(TextField).at(1), 'typo');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Save and reconnect'), findsOneWidget);

        connectError = PlatformException(
          code: 'LoginRejectedException',
          message: 'rejected',
          details: {'retryable': false},
        );
        await tester.tap(find.text('Save and reconnect'));
        for (var i = 0; i < 20 && connectCalls < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        expect(disconnectCalls, greaterThanOrEqualTo(1));
        expect(find.text('Connection failed'), findsOneWidget);
        expect((await SoulseekCredentials.load())!.password, 'pass');

        // Успешный вход с новыми данными — теперь они сохраняются.
        connectError = null;
        await tester.tap(find.text('Connect'));
        for (var i = 0; i < 20 && connectCalls < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        expect(find.text('Connected'), findsOneWidget);
        expect((await SoulseekCredentials.load())!.password, 'typo');
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
