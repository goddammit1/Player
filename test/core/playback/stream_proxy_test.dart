// Тесты локального прокси десктопного плеера на фейковом upstream.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/stream_proxy.dart';
import 'package:player/sources/playback_source.dart';

List<int> _bytes(int from, int count) =>
    List<int>.generate(count, (i) => (from + i) % 251);

/// Upstream с поддержкой Range: отдаёт [data] кусками по [chunk] байт с
/// паузой [delay] между ними.
class _Upstream {
  _Upstream(this.data);

  final List<int> data;
  int chunk = 64 * 1024;
  Duration delay = Duration.zero;
  int status = 200;

  /// Оборвать полный ответ после стольких байт (Content-Length — полный).
  int? cutAfter;

  /// После [cutAfter] байт не закрывать ответ, а зависнуть.
  bool hang = false;
  final _hung = Completer<void>();

  final requests = <String?>[];
  late HttpServer _server;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/track.mp3');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    requests.add(range);
    final res = req.response;
    if (status != 200) {
      res.statusCode = status;
      await res.close();
      return;
    }
    var start = 0, end = data.length;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!) + 1;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-${end - 1}/${data.length}');
    }
    res.headers.contentType = ContentType('audio', 'mpeg');
    res.contentLength = end - start;
    final limit = cutAfter == null ? end : start + cutAfter!;
    try {
      for (var i = start; i < end && i < limit; i += chunk) {
        res.add(data.sublist(i, [i + chunk, end, limit].reduce(
            (a, b) => a < b ? a : b)));
        await res.flush();
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
      if (hang && limit < end) await _hung.future;
      // При обрыве close() с недостающими байтами рвёт соединение.
      await res.close();
    } catch (_) {}
  }

  Future<void> stop() {
    if (!_hung.isCompleted) _hung.complete();
    return _server.close(force: true);
  }
}

Future<HttpClientResponse> _get(Uri url, {String? range}) async {
  final client = HttpClient();
  final req = await client.getUrl(url);
  if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
  return req.close();
}

Future<List<int>> _body(HttpClientResponse res) async {
  final out = <int>[];
  await for (final c in res) {
    out.addAll(c);
  }
  return out;
}

Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory dir;
  late _Upstream upstream;
  late StreamProxy proxy;
  final data = _bytes(0, 300000);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stream_proxy_test');
    upstream = _Upstream(data);
    await upstream.start();
    proxy = StreamProxy(
      pollInterval: const Duration(milliseconds: 5),
      stallTimeout: const Duration(seconds: 2),
      seekAheadBytes: 64 * 1024,
    );
  });

  tearDown(() async {
    await proxy.close();
    await upstream.stop();
    await dir.delete(recursive: true);
  });

  String cachePath() => '${dir.path}${Platform.pathSeparator}muzmo_1.mp3';

  RemoteStream remote() => RemoteStream(
        upstream.uri,
        headers: const {'Referer': 'https://muzmo/'},
        cachePath: cachePath(),
      );

  group('RemoteStream with cache', () {
    test('serves the whole file and publishes it to the cache', () async {
      final url = await proxy.urlFor(remote());
      expect(url.host, '127.0.0.1');
      expect(url.path, endsWith('.mp3'));

      final res = await _get(url);
      expect(res.statusCode, 200);
      expect(res.contentLength, data.length);
      expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(await _body(res), data);

      await _until(() => File(cachePath()).existsSync());
      expect(await File(cachePath()).readAsBytes(), data);
      expect(File('${cachePath()}.stream.part').existsSync(), isFalse);
      expect(upstream.requests, [null]);
    });

    test('range request returns 206 with exact bytes', () async {
      final url = await proxy.urlFor(remote());
      final res = await _get(url, range: 'bytes=1000-1999');

      expect(res.statusCode, HttpStatus.partialContent);
      expect(res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 1000-1999/300000');
      expect(await _body(res), data.sublist(1000, 2000));
    });

    test('open-ended range reads to the end', () async {
      final url = await proxy.urlFor(remote());
      final res = await _get(url, range: 'bytes=299000-');
      expect(res.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 299000-299999/300000');
      expect(await _body(res), data.sublist(299000));
    });

    test('seek far ahead of the download goes straight to upstream',
        () async {
      upstream
        ..chunk = 8 * 1024
        ..delay = const Duration(milliseconds: 30);
      final url = await proxy.urlFor(remote());
      await _until(() => upstream.requests.isNotEmpty);

      final res = await _get(url, range: 'bytes=250000-');
      expect(res.statusCode, HttpStatus.partialContent);
      expect(await _body(res), data.sublist(250000));
      expect(upstream.requests, contains('bytes=250000-299999'));
    });

    test('upstream error → 502 and nothing is cached', () async {
      upstream.status = 404;
      final url = await proxy.urlFor(remote());
      final res = await _get(url);
      expect(res.statusCode, HttpStatus.badGateway);
      await res.drain<void>();

      expect(File(cachePath()).existsSync(), isFalse);
      expect(File('${cachePath()}.stream.part').existsSync(), isFalse);
    });

    test('truncated upstream fails the reader and is not cached', () async {
      upstream
        ..cutAfter = 100000
        ..chunk = 16 * 1024;
      final url = await proxy.urlFor(remote());
      final res = await _get(url);

      await expectLater(_body(res), throwsA(anything));
      await _until(() => !File('${cachePath()}.stream.part').existsSync());
      expect(File(cachePath()).existsSync(), isFalse);
    });

    test('hung upstream fails the download after stallTimeout', () async {
      upstream
        ..cutAfter = 50000
        ..hang = true;
      final quick = StreamProxy(stallTimeout: const Duration(milliseconds: 200));
      addTearDown(quick.close);
      await quick.urlFor(remote());
      await _until(() => quick.downloadFor(cachePath()) == null);
      expect(File('${cachePath()}.stream.part').existsSync(), isFalse);
      expect(File(cachePath()).existsSync(), isFalse);
    });

    test('publishing waits until the open reader is closed', () async {
      final big = _bytes(0, 6 * 1024 * 1024);
      final up = _Upstream(big);
      await up.start();
      addTearDown(up.stop);
      final path = '${dir.path}${Platform.pathSeparator}big.mp3';
      final url = await proxy.urlFor(RemoteStream(up.uri, cachePath: path));

      final res = await _get(url);
      final first = Completer<void>();
      final sub = res.listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      sub.pause();

      final download = proxy.downloadFor(path)!;
      await _until(() => download.written == big.length);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(download.readers, 1);
      expect(File(path).existsSync(), isFalse);

      await sub.cancel();
      await _until(() => File(path).existsSync());
      expect(File('$path.stream.part').existsSync(), isFalse);
      expect(await File(path).length(), big.length);
    });

    test('already cached file is served without upstream', () async {
      await File(cachePath()).writeAsBytes(data);
      final url = await proxy.urlFor(remote());
      final res = await _get(url, range: 'bytes=10-19');
      expect(await _body(res), data.sublist(10, 20));
      expect(upstream.requests, isEmpty);
    });

    test('evicted idle download is cancelled', () async {
      upstream
        ..chunk = 4 * 1024
        ..delay = const Duration(milliseconds: 20);
      final small = StreamProxy(maxEntries: 1);
      addTearDown(small.close);
      await small.urlFor(remote());
      await _until(() => upstream.requests.isNotEmpty);
      final download = small.downloadFor(cachePath())!;

      await small.urlFor(GrowingFile(
        partPath: '${dir.path}/x.part',
        totalBytes: 10,
        contentType: 'audio/flac',
        completion: Completer<String>().future,
      ));
      await _until(() => download.failed);
      await _until(() => !File('${cachePath()}.stream.part').existsSync());
    });
  });

  group('GrowingFile', () {
    test('streams the part file while it grows', () async {
      final part = File('${dir.path}/slsk.part');
      await part.writeAsBytes(_bytes(0, 1000));
      final completion = Completer<String>();
      final url = await proxy.urlFor(GrowingFile(
        partPath: part.path,
        totalBytes: 3000,
        contentType: 'audio/flac',
        completion: completion.future,
      ));

      final res = await _get(url, range: 'bytes=0-');
      expect(res.statusCode, HttpStatus.partialContent);
      expect(res.headers.contentType?.mimeType, 'audio/flac');
      final body = _body(res);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await part.writeAsBytes(_bytes(1000, 2000), mode: FileMode.append);

      expect(await body, _bytes(0, 3000));
      completion.complete(part.path);
    });
  });

  test('unknown id → 404', () async {
    final url = await proxy.urlFor(remote());
    final res = await _get(url.replace(path: '/999.mp3'));
    expect(res.statusCode, 404);
    await res.drain<void>();
  });
}
