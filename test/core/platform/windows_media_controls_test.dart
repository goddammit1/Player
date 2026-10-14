// Канал системных медиаконтролов Windows: метаданные и состояние уходят в
// натив, кнопки флайаута управляют ядром очереди.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/windows_media_controls.dart';
import 'package:player/core/playback/queue_engine.dart';

import '../playback/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('player/media_controls');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late FakeBackend backend;
  late QueueEngine engine;
  late WindowsMediaControls controls;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> fromNative(String method, Object? args) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await settle();
  }

  setUp(() async {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    backend = FakeBackend();
    engine = QueueEngine(backend: backend, environment: FakeEnvironment());
    await engine.ready;
    controls = WindowsMediaControls(engine)..attach();
    await settle();
  });

  tearDown(() async {
    await controls.dispose();
    await engine.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('track change sends metadata, playing state follows', () async {
    await engine.setQueue([
      track('a').copyWith(artworkUrl: 'https://img/a.jpg'),
      track('b'),
    ]);
    await settle();

    final update = calls.lastWhere((c) => c.method == 'update');
    expect(update.arguments, {
      'title': 'Title a',
      'artist': 'Artist',
      'album': '',
      'artwork': 'https://img/a.jpg',
    });
    final state = calls.lastWhere((c) => c.method == 'state');
    expect((state.arguments as Map)['playing'], isTrue);
  });

  test('restored track shows its duration before loading', () async {
    final env = FakeEnvironment()
      ..session = (
        queue: [track('a').copyWith(duration: const Duration(seconds: 200))],
        currentIndex: 0,
        positionMs: 0,
      );
    final restored = QueueEngine(backend: FakeBackend(), environment: env);
    await restored.ready;
    calls.clear();
    final c = WindowsMediaControls(restored)..attach();
    await settle();

    final state = calls.lastWhere((c) => c.method == 'state');
    expect(state.arguments, {
      'playing': false,
      'positionMs': 0,
      'durationMs': 200000,
    });
    await c.dispose();
    await restored.dispose();
  });

  test('local artwork is sent as a file path', () async {
    await engine.setQueue([track('a')]);
    await engine.updateCustomArtwork('a', r'C:\covers\a.png');
    await settle();
    final update = calls.lastWhere((c) => c.method == 'update');
    expect((update.arguments as Map)['artwork'], r'C:\covers\a.png');
  });

  test('flyout buttons drive the player', () async {
    await engine.setQueue([track('a'), track('b')]);
    await settle();

    await fromNative('onButton', 'pause');
    expect(backend.calls.last, 'pause');

    await fromNative('onButton', 'next');
    expect(engine.currentIndex, 1);

    backend.position = Duration.zero;
    await fromNative('onButton', 'previous');
    expect(engine.currentIndex, 0);

    await fromNative('onSeek', 42000);
    expect(backend.calls.last, 'seek:42');
  });

  test('clearing the queue clears the flyout', () async {
    await engine.setQueue([track('a')]);
    await engine.clearQueue();
    await settle();
    expect(calls.last.method, 'clear');
  });

  test('a seek jump resends the state, steady playback does not', () async {
    await engine.setQueue([track('a')]);
    await settle();
    final before = calls.where((c) => c.method == 'state').length;

    backend.emitPosition(const Duration(milliseconds: 200));
    await settle();
    expect(calls.where((c) => c.method == 'state').length, before);

    backend.emitPosition(const Duration(seconds: 60));
    await settle();
    expect(calls.where((c) => c.method == 'state').length, before + 1);
    expect((calls.last.arguments as Map)['positionMs'], 60000);
  });
}
