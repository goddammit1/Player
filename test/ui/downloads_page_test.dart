// Страница Downloads: группы загрузок Soulseek поверх списка готовых треков.
//
// Проверяется логика, которую не покрывает happy-path в
// soulseek_settings_connect_test.dart:
//   - пауза из прошлого запуска видна (её можно продолжить), ошибка прошлого
//     запуска и отменённая пользователем — нет;
//   - завершение загрузки этой сессии перечитывает кэш, даже если первое,
//     что страница о ней узнала, — уже «completed»;
//   - опрос getActiveTransfers идёт, только пока данные качаются;
//   - снимок, запрошенный раньше события, не откатывает его;
//   - SoulseekSessionTransfers отмечает трансферы по событиям.
//
// Канал Soulseek и сервис кэша — фейки (DI через конструктор / провайдер),
// без sqflite и platform channels.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/cached_tracks_service.dart';
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_platform_channel.dart';
import 'package:player/sources/soulseek_session_transfers.dart';
import 'package:player/ui/pages/downloads_page.dart';

import '../setup/test_harness.dart';

class _FakePlayer extends Fake implements PlayerServiceInterface {
  @override
  Stream<MediaItem?> get mediaItem => BehaviorSubject<MediaItem?>.seeded(null);
}

/// Пустой кэш; считает перечитывания.
class _FakeService extends CachedTracksService {
  int loads = 0;

  @override
  Future<List<CachedTrack>> loadAll() async {
    loads++;
    return const [];
  }
}

class _FakeChannel extends Fake implements SoulseekPlatformChannel {
  final _events = StreamController<SoulseekTransferEvent>.broadcast();
  List<SoulseekTransferInfo> snapshot = const [];
  int snapshotCalls = 0;

  /// Задан — ответ getActiveTransfers ждёт его (снимок «в пути»).
  Completer<void>? gate;

  @override
  bool get isAvailable => true;

  @override
  Stream<SoulseekTransferEvent> get transferEvents => _events.stream;

  @override
  Future<List<SoulseekTransferInfo>> getActiveTransfers({
    bool includeTerminal = false,
  }) async {
    snapshotCalls++;
    final taken = snapshot;
    await gate?.future;
    return taken;
  }

  void emit(SoulseekTransferInfo info) =>
      _events.add(SoulseekTransferEvent(info));

  Future<void> close() => _events.close();
}

SoulseekTransferInfo _t(
  String id,
  SoulseekTransferState state, {
  int received = 0,
}) =>
    SoulseekTransferInfo(
      downloadId: id,
      state: state,
      bytesReceived: received,
      totalBytes: 100,
      title: 'Song $id',
      artist: 'Artist',
      remoteFilename: 'music/Artist/Song $id.flac',
    );

void main() {
  TestHarness.ensureInitialized();

  late _FakeChannel channel;
  late _FakeService service;

  setUp(() {
    ArtworkHelper.disableDbReadsForTesting = true;
    channel = _FakeChannel();
    service = _FakeService();
    SoulseekSessionTransfers.instance.resetForTesting();
  });

  tearDown(() async {
    ArtworkHelper.disableDbReadsForTesting = false;
    SoulseekSessionTransfers.instance.resetForTesting();
    await channel.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(_FakePlayer()),
        cachedTracksServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(home: DownloadsPage(channel: channel)),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// Закрыть страницу — таймеры опроса и обновления кэша гасятся.
  Future<void> closePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets(
      'пауза из прошлого запуска видна с Resume; ошибка прошлого запуска и '
      'отменённая скрыты', (tester) async {
    SoulseekSessionTransfers.instance
      ..add('cancelled')
      ..add('failedNow');
    channel.snapshot = [
      _t('pausedOld', SoulseekTransferState.paused, received: 40),
      _t('failedOld', SoulseekTransferState.failed),
      _t('cancelled', SoulseekTransferState.cancelled),
      _t('failedNow', SoulseekTransferState.failed),
    ];
    await pumpPage(tester);

    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('Song pausedOld'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsOneWidget);

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Song failedNow'), findsOneWidget);
    expect(find.text('Song failedOld'), findsNothing);
    expect(find.text('Song cancelled'), findsNothing);

    await closePage(tester);
  });

  testWidgets(
      'загрузка этой сессии, впервые увиденная как completed, перечитывает '
      'кэш (и ещё раз — страховкой)', (tester) async {
    await pumpPage(tester);
    expect(service.loads, 1);

    channel.emit(_t('done', SoulseekTransferState.completed, received: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(service.loads, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(service.loads, 3);

    await closePage(tester);
  });

  testWidgets('завершённая в прошлом запуске кэш не перечитывает',
      (tester) async {
    channel.snapshot = [_t('old', SoulseekTransferState.completed)];
    await pumpPage(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(service.loads, 1);

    await closePage(tester);
  });

  testWidgets('опрос идёт, только пока данные качаются', (tester) async {
    channel.snapshot = [
      _t('d', SoulseekTransferState.downloading, received: 10),
    ];
    await pumpPage(tester);
    final start = channel.snapshotCalls;
    await tester.pump(const Duration(milliseconds: 3100));
    expect(channel.snapshotCalls - start, greaterThanOrEqualTo(3));

    // Пауза: события сообщают о смене состояния, опрос не нужен.
    channel.snapshot = [_t('d', SoulseekTransferState.paused, received: 10)];
    channel.emit(_t('d', SoulseekTransferState.paused, received: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    final afterPause = channel.snapshotCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(channel.snapshotCalls, afterPause);

    await closePage(tester);
  });

  testWidgets('снимок, запрошенный до события, не откатывает и не удаляет его',
      (tester) async {
    channel.gate = Completer<void>();
    channel.snapshot = const []; // снимок сделан, когда загрузки ещё не было
    await pumpPage(tester);

    channel.emit(_t('new', SoulseekTransferState.queued));
    await tester.pump();
    await tester.pump();
    expect(find.text('Song new'), findsOneWidget);

    channel.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Song new'), findsOneWidget);

    await closePage(tester);
  });

  test('SoulseekSessionTransfers отмечает трансферы по событиям', () async {
    final tracker = SoulseekSessionTransfers.instance;
    tracker.start(channel);
    expect(tracker.contains('x'), isFalse);
    channel.emit(_t('x', SoulseekTransferState.queued));
    await Future<void>.delayed(Duration.zero);
    expect(tracker.contains('x'), isTrue);
    tracker.resetForTesting();
    expect(tracker.contains('x'), isFalse);
  });
}
