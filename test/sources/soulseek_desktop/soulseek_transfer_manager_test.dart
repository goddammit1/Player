// Менеджер загрузок Soulseek на Windows (порт SoulseekTransferManager.kt)
// на фейковом мосте: очередь, retry, pause/resume/cancel, публикация `.part`
// в кэш с учётом открытых читателей, восстановление после перезапуска.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player/sources/growing_file_reader.dart';
import 'package:player/sources/soulseek_desktop/soulseek_desktop_cache.dart';
import 'package:player/sources/soulseek_desktop/soulseek_desktop_store.dart';
import 'package:player/sources/soulseek_desktop/soulseek_transfer_manager.dart';
import 'package:player/sources/soulseek_models.dart';

import 'fake_bridge.dart';

void main() {
  late Directory tmp;
  late FakeBridge bridge;
  late MemorySoulseekDesktopStore store;
  late SoulseekDesktopCache cache;
  late SoulseekTransferManager manager;
  late List<SoulseekTransferInfo> events;

  SoulseekTransferManager createManager({int maxConcurrent = 3}) {
    final m = SoulseekTransferManager(
      bridge: bridge,
      store: store,
      cache: cache,
      maxConcurrentDownloads: maxConcurrent,
      retryDelay: (_) => Duration.zero,
    );
    m.events.listen(events.add);
    bridge.events.listen(m.handleBridgeEvent);
    return m;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('slsk_tm_');
    bridge = FakeBridge();
    store = MemorySoulseekDesktopStore();
    cache = SoulseekDesktopCache(
      store: store,
      cacheDir: tmp.path,
      publishWait: const Duration(milliseconds: 50),
    );
    events = [];
    manager = createManager();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<SoulseekDownloadResult> start(String key, {int size = 8}) =>
      manager.startDownload(
        downloadId: 'dl_$key',
        peerUsername: 'peer',
        remoteFilename: r'Music\Album\01.mp3',
        sizeBytes: size,
        cacheKey: key,
        fileExtension: 'mp3',
        title: 'Song',
        artist: 'Artist',
        durationSeconds: 180,
      );

  /// Мост «дописал» `.part` и прислал downloadComplete с его путём.
  Future<void> completeInBridge(String key, {List<int>? bytes}) async {
    final part = File(cache.partPath(key));
    await part.parent.create(recursive: true);
    await part.writeAsBytes(bytes ?? List.filled(8, 1));
    bridge.emit({
      'eventType': 'downloadComplete',
      'downloadId': bridge.lastBridgeId(key),
      'state': 'Succeeded',
      'bytesReceived': 8,
      'totalBytes': 8,
      'localPath': part.path,
    });
  }

  Future<SoulseekTransferInfo> nextState(
      String key, SoulseekTransferState state) {
    return manager.events
        .firstWhere((e) => e.downloadId == 'dl_$key' && e.state == state)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('новая загрузка уходит в мост с путём .part в каталоге incomplete',
      () async {
    final result = await start('k1');
    await settle();

    expect(result.cacheHit, isFalse);
    expect(result.result, 'dl_k1');
    expect(result.partPath, p.join(tmp.path, 'incomplete', 'k1.part'));
    final payload = bridge.lastPayload('startDownload');
    expect(payload['partPath'], result.partPath);
    expect(payload['localDirectory'], tmp.path);
    expect(payload['peerUsername'], 'peer');
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);
  });

  test('downloadComplete: .part публикуется в кэш, событие COMPLETED с '
      'итоговым путём', () async {
    await start('k1');
    await settle();
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');

    final info = await completed;
    final finalPath = p.join(tmp.path, 'k1.mp3');
    expect(info.localPath, finalPath);
    expect(File(finalPath).existsSync(), isTrue);
    expect(File(cache.partPath('k1')).existsSync(), isFalse);

    final entry = await cache.getCacheEntry('k1');
    expect(entry, isNotNull);
    expect(entry!.title, 'Song');
    expect(entry.extension, 'mp3');
    expect(store.transfers['dl_k1']!.state, 'COMPLETED');
  });

  test('повторный startDownload готового файла — cache hit без моста',
      () async {
    await start('k1');
    await settle();
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;
    bridge.calls.clear();

    final again = await start('k1');
    expect(again.cacheHit, isTrue);
    expect(again.result, p.join(tmp.path, 'k1.mp3'));
    expect(bridge.methods, isNot(contains('startDownload')));
  });

  test('открытый читателем .part публикуется копией и удаляется после '
      'закрытия читателя', () async {
    await start('k1');
    await settle();
    final partPath = cache.partPath('k1');
    // Прокси стримит .part: лиза держится дольше publishWait.
    FileReadLeases.acquire(partPath);
    final reader = await (File(partPath)..createSync(recursive: true)).open();
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');

    final info = await completed;
    expect(File(info.localPath!).lengthSync(), 8);

    await reader.close();
    FileReadLeases.release(partPath);
    await settle();
    expect(File(partPath).existsSync(), isFalse);
  });

  test('пока читатели открыты недолго, публикация ждёт и переименовывает',
      () async {
    await start('k1');
    await settle();
    final partPath = cache.partPath('k1');
    FileReadLeases.acquire(partPath);
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await settle();
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading,
        reason: 'до закрытия читателя трансфер не завершён');

    FileReadLeases.release(partPath);
    final info = await completed;
    expect(info.localPath, p.join(tmp.path, 'k1.mp3'));
  });

  test('одновременный запрос того же cacheKey присоединяется к загрузке',
      () async {
    await start('k1');
    final second = await manager.startDownload(
      downloadId: 'dl_other',
      peerUsername: 'peer',
      remoteFilename: r'Music\Album\01.mp3',
      sizeBytes: 8,
      cacheKey: 'k1',
      fileExtension: 'mp3',
    );
    expect(second.result, 'dl_k1');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(1));
  });

  Future<SoulseekDownloadResult> startUntitled(String key) =>
      manager.startDownload(
        downloadId: 'dl_$key',
        peerUsername: 'peer',
        remoteFilename: r'Music\Artist\Album\01 - Song.mp3',
        sizeBytes: 8,
        cacheKey: key,
        fileExtension: 'mp3',
      );

  test('загрузка без метаданных (prefetch) получает их от присоединившегося '
      'запроса и публикуется с title', () async {
    await startUntitled('k1');
    await start('k1');
    await settle();
    expect(manager.getTransfer('dl_k1')!.title, 'Song');

    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    final info = await completed;
    expect(info.title, 'Song');
    expect(info.artist, 'Artist');
    final entry = (await cache.getAllCacheEntries()).single;
    expect(entry.title, 'Song');
    expect(entry.remoteFilename, r'Music\Artist\Album\01 - Song.mp3');
  });

  test('кэш-запись без title: remoteFilename для названия, cache hit '
      'дописывает метаданные', () async {
    await startUntitled('k1');
    await settle();
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    final info = await completed;
    expect(info.remoteFilename, r'Music\Artist\Album\01 - Song.mp3');

    var entry = (await cache.getAllCacheEntries()).single;
    expect(entry.title, isNull);
    expect(entry.remoteFilename, r'Music\Artist\Album\01 - Song.mp3');

    final again = await start('k1');
    expect(again.cacheHit, isTrue);
    entry = (await cache.getAllCacheEntries()).single;
    expect(entry.title, 'Song');
    expect(entry.artist, 'Artist');
    expect(entry.durationSeconds, 180);
  });

  test('retryable-неудача повторяется, затем успех', () async {
    await start('k1');
    await settle();
    bridge.emit({
      'eventType': 'downloadFailed',
      'downloadId': bridge.lastBridgeId('k1'),
      'state': 'Completed, Errored',
      'errorCode': 'UserOfflineException',
      'retryable': true,
    });
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);

    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;
  });

  test('неретрайная ошибка — FAILED с кодом моста', () async {
    await start('k1');
    await settle();
    final failed = nextState('k1', SoulseekTransferState.failed);
    bridge.emit({
      'eventType': 'downloadFailed',
      'downloadId': bridge.lastBridgeId('k1'),
      'state': 'Completed, Rejected',
      'errorCode': 'TransferRejectedException',
      'message': 'File not shared',
      'retryable': false,
    });
    final info = await failed;
    expect(info.errorCode, 'TransferRejectedException');
    expect(info.message, 'File not shared');
    expect(store.transfers['dl_k1']!.state, 'FAILED');
  });

  test('бюджет попыток исчерпан — FAILED', () async {
    await start('k1');
    final failed = nextState('k1', SoulseekTransferState.failed);
    for (var i = 0; i < SoulseekTransferManager.maxRetryAttempts; i++) {
      await settle();
      bridge.emit({
        'eventType': 'downloadFailed',
        'downloadId': bridge.lastBridgeId('k1'),
        'state': 'Completed, TimedOut',
        'errorCode': 'TimeoutException',
        'retryable': true,
      });
    }
    final info = await failed;
    expect(info.errorCode, 'TimeoutException');
  });

  test('ошибка вызова моста (не подключён) — FAILED', () async {
    bridge.handler = (method, _) async {
      if (method == 'startDownload') {
        throw const SoulseekException(
            'InvalidOperationException', 'Client not initialized');
      }
      return null;
    };
    final failed = nextState('k1', SoulseekTransferState.failed);
    await start('k1');
    expect((await failed).errorCode, 'InvalidOperationException');
  });

  test('pause отменяет передачу в мосте и сохраняет .part; resume '
      'перезапускает загрузку', () async {
    await start('k1');
    await settle();
    final part = File(cache.partPath('k1'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);

    await manager.pauseDownload('dl_k1');
    expect(bridge.methods, contains('cancelTransfer'));
    // Мост сообщает об отмене — для паузы это не ошибка.
    bridge.emit({
      'eventType': 'downloadFailed',
      'downloadId': bridge.lastBridgeId('k1'),
      'state': 'Cancelled',
      'errorCode': 'CANCELLED',
    });
    await settle();
    final paused = manager.getTransfer('dl_k1')!;
    expect(paused.state, SoulseekTransferState.paused);
    expect(paused.bytesReceived, 3);
    expect(part.existsSync(), isTrue);

    await manager.resumeDownload('dl_k1');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);
  });

  test('cancel — CANCELLED и удаление .part', () async {
    await start('k1');
    await settle();
    final part = File(cache.partPath('k1'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    await manager.cancelDownload('dl_k1');
    await settle();
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.cancelled);
    expect(part.existsSync(), isFalse);
  });

  test('лимит параллельных загрузок: вторая ждёт слота', () async {
    manager = createManager(maxConcurrent: 1);
    await start('k1');
    await start('k2');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(1));
    expect(manager.getTransfer('dl_k2')!.state, SoulseekTransferState.queued);

    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
    expect(bridge.lastPayload('startDownload')['cacheKey'], 'k2');
  });

  test('очередь у пира не держит слот: следующая загрузка стартует, а '
      'вышедшая из очереди идёт сверх лимита', () async {
    manager = createManager(maxConcurrent: 1);
    await start('k1');
    await settle();
    bridge.emit({
      'eventType': 'transferStateChanged',
      'downloadId': bridge.lastBridgeId('k1'),
      'state': 'Queued, Remotely',
      'bytesReceived': 0,
    });
    await settle();
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.queuedRemotely);

    await start('k2');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));

    // Пир k1 начал отдавать: слот занят k2, но k1 не прерывается.
    bridge.emit({
      'eventType': 'transferStateChanged',
      'downloadId': bridge.lastBridgeId('k1'),
      'state': 'InProgress',
      'bytesReceived': 0,
    });
    await settle();
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);

    // Обе завершаются, слот не «утекает»: третья загрузка стартует.
    final done1 = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await done1;
    final done2 = nextState('k2', SoulseekTransferState.completed);
    await completeInBridge('k2');
    await done2;
    await start('k3');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(3));
    await start('k4');
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(3),
        reason: 'лимит 1 соблюдается после возврата слотов');
  });

  test('restore: незавершённые — PAUSED при наличии .part, иначе FAILED',
      () async {
    store.transfers['dl_a'] = const SoulseekTransferRow(
      downloadId: 'dl_a',
      cacheKey: 'a',
      peerUsername: 'peer',
      remoteFilename: 'x.mp3',
      sizeBytes: 10,
      state: 'DOWNLOADING',
    );
    store.transfers['dl_b'] = const SoulseekTransferRow(
      downloadId: 'dl_b',
      cacheKey: 'b',
      peerUsername: 'peer',
      remoteFilename: 'y.mp3',
      sizeBytes: 10,
      state: 'QUEUED',
    );
    File(cache.partPath('a'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);

    await manager.restore();
    final a = manager.getTransfer('dl_a')!;
    expect(a.state, SoulseekTransferState.paused);
    expect(a.bytesReceived, 4);
    expect(manager.getTransfer('dl_b')!.state, SoulseekTransferState.failed);
    expect(store.transfers['dl_b']!.state, 'FAILED');
  });

  test('shutdown переводит активные загрузки в PAUSED', () async {
    await start('k1');
    await settle();
    await manager.shutdown();
    expect(store.transfers['dl_k1']!.state, 'PAUSED');
  });

  group('повтор и очистка списка', () {
    Future<void> failInBridge(String key) async {
      final failed = nextState(key, SoulseekTransferState.failed);
      bridge.emit({
        'eventType': 'downloadFailed',
        'downloadId': bridge.lastBridgeId(key),
        'state': 'Completed, Rejected',
        'errorCode': 'TransferRejectedException',
        'retryable': false,
      });
      await failed;
    }

    test('retry упавшей загрузки перезапускает её и доводит до конца',
        () async {
      await start('k1');
      await settle();
      await failInBridge('k1');
      expect(store.transfers['dl_k1']!.state, 'FAILED');

      expect(await manager.retryDownload('dl_k1'), isTrue);
      await settle();
      expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
      final payload = bridge.lastPayload('startDownload');
      expect(payload['peerUsername'], 'peer');
      expect(payload['remoteFilename'], r'Music\Album\01.mp3');
      expect(payload['cacheKey'], 'k1');
      expect(manager.getTransfer('dl_k1')!.state,
          SoulseekTransferState.downloading);

      final completed = nextState('k1', SoulseekTransferState.completed);
      await completeInBridge('k1');
      final info = await completed;
      expect(info.localPath, p.join(tmp.path, 'k1.mp3'));
      expect(info.title, 'Song');
      expect(store.transfers['dl_k1']!.state, 'COMPLETED');
    });

    test('retry после cancel начинает с нуля, событие отменённой попытки '
        'его не трогает', () async {
      await start('k1');
      await settle();
      File(cache.partPath('k1'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      final oldAttempt = bridge.lastBridgeId('k1');
      await manager.cancelDownload('dl_k1');
      await settle();

      expect(await manager.retryDownload('dl_k1'), isTrue);
      expect(manager.getTransfer('dl_k1')!.bytesReceived, 0);
      // Мост подтверждает отмену прошлой попытки уже после retry.
      bridge.emit({
        'eventType': 'downloadFailed',
        'downloadId': oldAttempt,
        'state': 'Cancelled',
        'errorCode': 'CANCELLED',
      });
      await settle();
      expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
      expect(bridge.lastBridgeId('k1'), isNot(oldAttempt));
      expect(manager.getTransfer('dl_k1')!.state,
          SoulseekTransferState.downloading);
    });

    test('retry не трогает завершённую, активную и неизвестную загрузку',
        () async {
      await start('k1');
      await settle();
      final completed = nextState('k1', SoulseekTransferState.completed);
      await completeInBridge('k1');
      await completed;
      await start('k2');
      await settle();
      bridge.calls.clear();

      expect(await manager.retryDownload('dl_k1'), isFalse);
      expect(await manager.retryDownload('dl_k2'), isFalse);
      expect(await manager.retryDownload('dl_missing'), isFalse);
      await settle();
      expect(bridge.methods, isNot(contains('startDownload')));
      expect(manager.getTransfer('dl_k1')!.state,
          SoulseekTransferState.completed);
    });

    test('clear убирает только завершённые; файлы кэша остаются', () async {
      // k1 — COMPLETED, k2 — FAILED, k3 — CANCELLED, k4 — идёт.
      await start('k1');
      await settle();
      final completed = nextState('k1', SoulseekTransferState.completed);
      await completeInBridge('k1');
      await completed;
      await start('k2');
      await settle();
      await failInBridge('k2');
      await start('k3');
      await settle();
      await manager.cancelDownload('dl_k3');
      await start('k4');
      await settle();

      expect(await manager.clearFinishedTransfers(), 3);
      expect(manager.getAllTransfers().map((t) => t.downloadId), ['dl_k4']);
      expect(manager.getTransfer('dl_k4')!.state,
          SoulseekTransferState.downloading);
      expect(manager.getTransfer('dl_k1'), isNull);
      expect(await manager.retryDownload('dl_k2'), isFalse);

      // Готовый файл и его запись в кэше на месте; строка COMPLETED нужна
      // кэшу для исходного имени файла.
      expect(File(p.join(tmp.path, 'k1.mp3')).existsSync(), isTrue);
      final entry = await cache.getCacheEntry('k1');
      expect(entry, isNotNull);
      expect(entry!.remoteFilename, r'Music\Album\01.mp3');
      expect(store.transfers.keys, unorderedEquals(['dl_k1', 'dl_k4']));

      // Повторная очистка — нечего убирать.
      expect(await manager.clearFinishedTransfers(), 0);
    });

    test('убранные трансферы не возвращаются после restore', () async {
      store.transfers['dl_a'] = const SoulseekTransferRow(
        downloadId: 'dl_a',
        cacheKey: 'a',
        peerUsername: 'peer',
        remoteFilename: 'x.mp3',
        sizeBytes: 10,
        state: 'DOWNLOADING',
      );
      await manager.restore();
      expect(manager.getTransfer('dl_a')!.state, SoulseekTransferState.failed);

      expect(await manager.clearFinishedTransfers(), 1);
      expect(store.transfers, isEmpty);

      final restarted = createManager();
      await restarted.restore();
      expect(restarted.getAllTransfers(), isEmpty);
    });

    test('новая загрузка того же файла после clear стартует заново',
        () async {
      await start('k1');
      await settle();
      await failInBridge('k1');
      await manager.clearFinishedTransfers();

      await start('k1');
      await settle();
      expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
      expect(manager.getTransfer('dl_k1')!.state,
          SoulseekTransferState.downloading);
    });
  });

  group('кэш', () {
    Future<void> put(String key, int size, {bool pinned = false, int age = 0}) async {
      final path = p.join(tmp.path, '$key.mp3');
      await File(path).writeAsBytes(List.filled(size, 0));
      final at = DateTime(2026, 1, 1).add(Duration(minutes: age));
      await store.upsertCacheEntry(SoulseekCacheRow(
        cacheKey: key,
        localPath: path,
        sizeBytes: size,
        complete: true,
        lastAccessAt: at,
        cachedAt: at,
        pinned: pinned,
      ));
    }

    test('LRU-вытеснение пропускает закреплённые', () async {
      await put('old', 10, pinned: true, age: 0);
      await put('mid', 10, age: 1);
      await put('new', 10, age: 2);
      await cache.updateMaxCacheSizeBytes(20);

      expect(store.cache.keys, unorderedEquals(['old', 'new']));
      expect(File(p.join(tmp.path, 'mid.mp3')).existsSync(), isFalse);
    });

    test('запись о пропавшем файле удаляется при обращении', () async {
      await put('gone', 5);
      File(p.join(tmp.path, 'gone.mp3')).deleteSync();
      expect(await cache.getCacheEntry('gone'), isNull);
      expect(store.cache, isNot(contains('gone')));
    });

    test('removeCache удаляет файл, остаток .part и записи трансферов',
        () async {
      await put('k', 5);
      File(cache.partPath('k'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      store.transfers['dl_k'] = const SoulseekTransferRow(
        downloadId: 'dl_k',
        cacheKey: 'k',
        peerUsername: 'peer',
        remoteFilename: 'x.mp3',
        sizeBytes: 5,
        state: 'COMPLETED',
      );
      expect(await cache.removeCache('k'), isTrue);
      expect(File(p.join(tmp.path, 'k.mp3')).existsSync(), isFalse);
      expect(File(cache.partPath('k')).existsSync(), isFalse);
      expect(store.transfers, isEmpty);
    });

    test('ключ с разделителями пути отклоняется', () {
      expect(SoulseekDesktopCache.sanitizeCacheKey(r'..\evil'), isNull);
      expect(SoulseekDesktopCache.sanitizeCacheKey('a/b'), isNull);
      expect(SoulseekDesktopCache.sanitizeCacheKey('a:b'), 'a_b');
      expect(() => cache.partPath('../x'), throwsA(isA<SoulseekException>()));
    });
  });

  test('устаревшее событие прошлой попытки не отменяет возобновлённую '
      'загрузку', () async {
    await start('k1');
    await settle();
    final oldId = bridge.lastBridgeId('k1');
    await manager.pauseDownload('dl_k1');
    await manager.resumeDownload('dl_k1');
    await settle();
    // Отмена паузой доходит из моста уже после resume.
    bridge.emit({
      'eventType': 'downloadFailed',
      'downloadId': oldId,
      'state': 'Cancelled',
      'errorCode': 'CANCELLED',
    });
    await settle();
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
    expect(bridge.lastBridgeId('k1'), isNot(oldId));
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);

    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;
  });

  test('pause → resume в ожидании слота не запускает вторую загрузку',
      () async {
    manager = createManager(maxConcurrent: 1);
    await start('k1');
    await start('k2');
    await settle();
    await manager.pauseDownload('dl_k2');
    await manager.resumeDownload('dl_k2');
    // Повторный resume идущей загрузки — no-op.
    await manager.resumeDownload('dl_k2');

    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;
    await settle();
    final k2Starts = bridge.calls
        .where((c) => c.$1 == 'startDownload' && c.$2.contains('"k2"'));
    expect(k2Starts, hasLength(1));
  });

  test('запрос PAUSED-загрузки возобновляет её', () async {
    await start('k1');
    await settle();
    final oldId = bridge.lastBridgeId('k1');
    await manager.pauseDownload('dl_k1');
    bridge.emit({
      'eventType': 'downloadFailed',
      'downloadId': oldId,
      'state': 'Cancelled',
      'errorCode': 'CANCELLED',
    });
    await settle();

    final again = await start('k1');
    await settle();
    expect(again.result, 'dl_k1');
    expect(bridge.methods.where((m) => m == 'startDownload'), hasLength(2));
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.downloading);
  });

  test('pause / cancel после завершения не трогают COMPLETED', () async {
    await start('k1');
    await settle();
    final completed = nextState('k1', SoulseekTransferState.completed);
    await completeInBridge('k1');
    await completed;

    await manager.pauseDownload('dl_k1');
    await manager.cancelDownload('dl_k1');
    expect(manager.getTransfer('dl_k1')!.state,
        SoulseekTransferState.completed);
    expect(store.transfers['dl_k1']!.state, 'COMPLETED');
  });

  test('InProgress из моста — DOWNLOADING', () {
    expect(SoulseekTransferState.fromString('InProgress'),
        SoulseekTransferState.downloading);
  });
}
