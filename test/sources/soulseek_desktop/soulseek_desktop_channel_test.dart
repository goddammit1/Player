// DesktopSoulseekChannel на фейковом мосте: состояние соединения,
// переподключение по образцу slskd, вход с другого устройства, ленивое
// подключение сохранёнными учётными данными, потоковые результаты поиска.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_desktop/soulseek_desktop_channel.dart';
import 'package:player/sources/soulseek_desktop/soulseek_desktop_store.dart';
import 'package:player/sources/soulseek_models.dart';

import 'fake_bridge.dart';

void main() {
  late Directory tmp;
  late FakeBridge bridge;
  late DesktopSoulseekChannel channel;
  late List<SoulseekConnectionEvent> connection;
  ({String username, String password})? saved;
  var connectFailures = <SoulseekException>[];

  String connected(String user) =>
      jsonEncode({'username': user, 'state': 'Connected, LoggedIn'});

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('slsk_ch_');
    saved = null;
    connectFailures = [];
    bridge = FakeBridge(handler: (method, payload) async {
      switch (method) {
        case 'connect':
          if (connectFailures.isNotEmpty) throw connectFailures.removeAt(0);
          return connected(
              (jsonDecode(payload) as Map)['username'] as String);
        case 'search':
          return jsonEncode([
            {'resultId': 'r1', 'username': 'peer', 'filename': r'a\b.mp3'},
          ]);
      }
      return null;
    });
    channel = DesktopSoulseekChannel(
      bridge: bridge,
      store: MemorySoulseekDesktopStore(),
      cacheDirectory: () async => tmp.path,
      credentials: () async => saved,
      reconnectDelay: (_) => const Duration(milliseconds: 10),
      retryDelay: (_) => Duration.zero,
    );
    connection = [];
    channel.connectionEvents.listen(connection.add);
  });

  tearDown(() async {
    await channel.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> settle([int ms = 20]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> connect() => channel.connect(
        username: 'me',
        password: 'secret',
        listenPort: 50123,
      );

  test('connect передаёт учётные данные и порт, состояние connected',
      () async {
    final info = await channel.connect(
        username: 'me', password: 'secret', listenPort: 50123);
    expect(info.state, SoulseekConnectionState.connected);
    final payload = bridge.lastPayload('connect');
    expect(payload['username'], 'me');
    expect(payload['password'], 'secret');
    expect(payload['listenPort'], 50123);
    expect(await channel.getConnectionState(),
        SoulseekConnectionState.connected);
    await settle(0);
    expect(connection.last.state, SoulseekConnectionState.connected);
  });

  test('обрыв соединения — reconnecting и переподключение', () async {
    await connect();
    bridge.emit({
      'eventType': 'disconnected',
      'state': 'Disconnected',
      'errorCode': 'ConnectionException',
      'message': 'Remote connection closed',
    });
    await settle(0);
    expect(channel.connectionState, SoulseekConnectionState.reconnecting);

    await settle(60);
    expect(bridge.methods.where((m) => m == 'connect'), hasLength(2));
    expect(channel.connectionState, SoulseekConnectionState.connected);
  });

  test('переподключение повторяется с backoff, пока сеть не вернётся',
      () async {
    await connect();
    connectFailures = [
      const SoulseekException('SoulseekClientException', 'Failed to connect',
          retryable: true),
      const SoulseekException('SoulseekClientException', 'Failed to connect',
          retryable: true),
    ];
    bridge.emit({'eventType': 'disconnected', 'errorCode': 'IOException'});
    await settle(150);
    expect(bridge.methods.where((m) => m == 'connect'), hasLength(4));
    expect(channel.connectionState, SoulseekConnectionState.connected);
  });

  test('вход с другого устройства — без переподключения, с сообщением',
      () async {
    await connect();
    bridge.emit({
      'eventType': 'disconnected',
      'errorCode': 'KickedFromServerException',
      'message': 'Kicked from server',
    });
    await settle(60);
    expect(bridge.methods.where((m) => m == 'connect'), hasLength(1));
    expect(channel.connectionState, SoulseekConnectionState.disconnected);
    expect(connection.last.message, DesktopSoulseekChannel.kickedMessage);
  });

  test('неверный пароль при переподключении — failed, попытки прекращаются',
      () async {
    await connect();
    connectFailures = [
      const SoulseekException('LoginRejectedException', 'INVALIDPASS'),
    ];
    bridge.emit({'eventType': 'disconnected', 'errorCode': 'IOException'});
    await settle(80);
    expect(bridge.methods.where((m) => m == 'connect'), hasLength(2));
    expect(channel.connectionState, SoulseekConnectionState.failed);
  });

  test('ручное отключение: загрузки на паузу, без переподключения',
      () async {
    await connect();
    await channel.startDownload(
      downloadId: 'dl_k',
      peerUsername: 'peer',
      remoteFilename: 'x.mp3',
      sizeBytes: 10,
      cacheKey: 'k',
      fileExtension: 'mp3',
    );
    await settle();

    await channel.disconnect();
    bridge.emit({
      'eventType': 'disconnected',
      'errorCode': 'ObjectDisposedException',
    });
    await settle(60);

    expect(bridge.methods, containsAllInOrder(['cancelTransfer', 'disconnect']));
    expect((await channel.getTransfer('dl_k'))!.state,
        SoulseekTransferState.paused);
    expect(bridge.methods.where((m) => m == 'connect'), hasLength(1));
    expect(channel.connectionState, SoulseekConnectionState.disconnected);
  });

  test('поиск без соединения подключается сохранёнными учётными данными',
      () async {
    saved = (username: 'saved', password: 'pw');
    await channel.updateNativeSettings(listenPort: 40000);
    final results = await channel.search(requestId: 'q1', query: ' song ');

    expect(bridge.methods.toList(), ['connect', 'search']);
    expect(bridge.lastPayload('connect')['username'], 'saved');
    expect(bridge.lastPayload('connect')['listenPort'], 40000);
    expect(bridge.lastPayload('search')['query'], 'song');
    expect(results.single.filename, r'a\b.mp3');
  });

  test('без сохранённых учётных данных поиск не подключается', () async {
    await channel.search(requestId: 'q1', query: 'song');
    expect(bridge.methods.toList(), ['search']);
  });

  test('после ручного отключения автоподключения нет', () async {
    saved = (username: 'saved', password: 'pw');
    await connect();
    await channel.disconnect();
    bridge.calls.clear();
    await channel.search(requestId: 'q1', query: 'song');
    expect(bridge.methods.toList(), ['search']);
  });

  test('searchProgress моста уходит в поток searchProgress', () async {
    final progress = channel.searchProgress.first;
    await channel.startService();
    bridge.emit({
      'eventType': 'searchProgress',
      'requestId': 'q1',
      'results': [
        {'resultId': 'r1', 'username': 'peer', 'filename': r'a\b.flac'},
      ],
    });
    final e = await progress.timeout(const Duration(seconds: 2));
    expect(e.requestId, 'q1');
    expect(e.results.single.filename, r'a\b.flac');
  });

  test('новый подписчик сразу получает текущее состояние соединения',
      () async {
    await connect();
    final first = await channel.connectionEvents.first;
    expect(first.state, SoulseekConnectionState.connected);
  });

  test('готовый файл из кэша не требует подключения', () async {
    saved = (username: 'saved', password: 'pw');
    final store = MemorySoulseekDesktopStore();
    final file = File('${tmp.path}${Platform.pathSeparator}k.mp3')
      ..writeAsBytesSync([1, 2]);
    await store.upsertCacheEntry(SoulseekCacheRow(
      cacheKey: 'k',
      localPath: file.path,
      sizeBytes: 2,
      complete: true,
      lastAccessAt: DateTime(2026),
      cachedAt: DateTime(2026),
    ));
    final ch = DesktopSoulseekChannel(
      bridge: bridge,
      store: store,
      cacheDirectory: () async => tmp.path,
      credentials: () async => saved,
    );
    final result = await ch.startDownload(
      downloadId: 'dl_k',
      peerUsername: 'peer',
      remoteFilename: 'x.mp3',
      sizeBytes: 2,
      cacheKey: 'k',
    );
    expect(result.cacheHit, isTrue);
    expect(bridge.methods, isEmpty);
    await ch.dispose();
  });
}
