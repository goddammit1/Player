// lib/core/playback/stream_proxy.dart
//
// Локальный HTTP-прокси десктопного плеера на 127.0.0.1.
//
// media_kit (libmpv) играет URL, но не умеет «стримить и одновременно писать
// в наш кэш» и читать растущий файл. Прокси закрывает оба случая:
//
// - [RemoteStream] с `cachePath` (замена `LockCachingAudioSource`): одна
//   загрузка upstream в `<cachePath>.part`, range-запросы плеера читаются из
//   `.part` по мере записи; запрос далеко впереди загруженного (seek в
//   некэшированном треке) уходит отдельным range-запросом в upstream.
//   По завершении `.part` атомарно публикуется в кэш — частичные загрузки в
//   кэш не попадают.
// - [GrowingFile] (Soulseek во время загрузки): чтение `.part` с ожиданием
//   прироста, как в [SoulseekStreamAudioSource].
//
// Windows: файл, открытый на чтение, нельзя переименовать (errno 32).
// Прокси сам владеет и записью, и чтением, поэтому rename делается, когда
// закрыты писатель и все читатели `.part`, — без гонок.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../sources/growing_file_reader.dart';
import '../../sources/playback_source.dart';

void _log(String msg) => debugPrint('[StreamProxy] $msg');

class StreamProxy {
  StreamProxy({
    HttpClient? client,
    this.pollInterval = const Duration(milliseconds: 50),
    this.stallTimeout = const Duration(seconds: 45),
    this.seekAheadBytes = 512 * 1024,
    this.maxEntries = 4,
  }) : _client = client ?? (HttpClient()..autoUncompress = false);

  final HttpClient _client;

  /// Как часто читатель проверяет прирост `.part`.
  final Duration pollInterval;

  /// Сколько ждать прироста `.part`, прежде чем считать загрузку зависшей.
  final Duration stallTimeout;

  /// Запрос дальше загруженного больше чем на столько байт идёт напрямую в
  /// upstream, а не ждёт, пока до него дойдёт загрузка.
  final int seekAheadBytes;

  /// Сколько последних источников держать зарегистрированными. Незавершённая
  /// загрузка вытесненного источника без читателей отменяется.
  final int maxEntries;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  int _nextId = 0;
  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();
  final Map<String, CachingDownload> _downloads = {};

  /// Идущие циклы загрузки (до закрытия `.part` писателем): [close] их ждёт.
  final Set<Future<void>> _running = {};

  /// URL, по которому плеер получит [source]. Для [RemoteStream] с кэшем
  /// загрузка стартует сразу.
  Future<Uri> urlFor(PlaybackSource source) async {
    final server = await _ensureServer();
    final _Entry entry;
    final String ext;
    switch (source) {
      case RemoteStream(:final cachePath?):
        entry = _CachingEntry(_downloadFor(source, cachePath));
        ext = p.extension(cachePath);
      case GrowingFile():
        entry = _GrowingEntry(source, GrowingFileReader(
          partPath: source.partPath,
          totalBytes: source.totalBytes,
          completion: source.completion,
          pollInterval: pollInterval,
          stallTimeout: stallTimeout,
        ));
        ext = '';
      default:
        throw ArgumentError.value(source, 'source', 'not proxied');
    }
    final id = '${_nextId++}';
    _entries[id] = entry;
    _evictEntries();
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: '/$id$ext',
    );
  }

  /// Загрузка в кэш по [cachePath] (общая для повторных запросов трека).
  @visibleForTesting
  CachingDownload? downloadFor(String cachePath) => _downloads[cachePath];

  CachingDownload _downloadFor(RemoteStream source, String cachePath) {
    final existing = _downloads[cachePath];
    if (existing != null && !existing.failed) return existing;
    final download = CachingDownload(
      client: _client,
      uri: source.uri,
      headers: source.headers,
      cachePath: cachePath,
      pollInterval: pollInterval,
      stallTimeout: stallTimeout,
      seekAheadBytes: seekAheadBytes,
      onSettled: (d) {
        if (identical(_downloads[cachePath], d)) _downloads.remove(cachePath);
      },
    );
    _downloads[cachePath] = download;
    final run = download.start();
    _running.add(run);
    unawaited(run.whenComplete(() => _running.remove(run)));
    return download;
  }

  void _evictEntries() {
    while (_entries.length > maxEntries) {
      final key = _entries.keys.first;
      final entry = _entries.remove(key)!;
      if (entry is _CachingEntry &&
          !_entries.values.any(
              (e) => e is _CachingEntry && identical(e.download, entry.download))) {
        entry.download.cancelIfIdle();
      }
    }
  }

  Future<HttpServer> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(server);
    return _starting ??= () async {
      try {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        s.listen(_handle, onError: (Object e) => _log('server: $e'));
        _server = s;
        _log('listening on 127.0.0.1:${s.port}');
        return s;
      } catch (_) {
        // Не кэшируем неудачный bind: следующий трек попробует снова.
        _starting = null;
        rethrow;
      }
    }();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final id = p.basenameWithoutExtension(request.uri.path);
      final entry = _entries[id];
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
      final body = await entry.open(range);
      if (body == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
      final start = body.start;
      final end = body.end; // исключая
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, body.contentType);
      if (body.total != null) {
        if (start >= body.total! && body.total! > 0) {
          await body.stream.listen(null).cancel();
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes */${body.total}');
          await response.close();
          return;
        }
        response.contentLength = end! - start;
        if (range != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-${end - 1}/${body.total}');
        }
      }
      if (request.method == 'HEAD') {
        await body.stream.listen(null).cancel();
        await response.close();
        return;
      }
      await response.addStream(body.stream);
      await response.close();
    } catch (e) {
      // Плеер закрыл соединение (seek / смена трека) или загрузка упала
      // посреди ответа — соединение просто обрывается.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// `bytes=a-b` / `bytes=a-` → (a, b + 1 | null); прочее — без range.
  static ({int start, int? end})? _parseRange(String? header) {
    if (header == null) return null;
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final start = int.parse(m.group(1)!);
    final endText = m.group(2)!;
    return (start: start, end: endText.isEmpty ? null : int.parse(endText) + 1);
  }

  Future<void> close() async {
    for (final d in _downloads.values.toList()) {
      d.cancel();
    }
    _downloads.clear();
    _entries.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    _client.close(force: true);
    // Писатели закрывают и удаляют `.part` асинхронно — дождаться, иначе
    // файл остаётся открытым после закрытия прокси.
    await Future.wait(_running.toList())
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
  }
}

/// Тело ответа прокси: байты [start, end) из файла длиной [total] (null — длина
/// неизвестна, отдаём поток как есть).
typedef ProxyBody = ({
  int start,
  int? end,
  int? total,
  String contentType,
  Stream<List<int>> stream,
});

sealed class _Entry {
  Future<ProxyBody?> open(({int start, int? end})? range);
}

final class _GrowingEntry extends _Entry {
  _GrowingEntry(this.source, this.reader);

  final GrowingFile source;
  final GrowingFileReader reader;

  @override
  Future<ProxyBody?> open(({int start, int? end})? range) async {
    final total = source.totalBytes;
    final start = range?.start ?? 0;
    final end = math.min(range?.end ?? total, total);
    return (
      start: start,
      end: end,
      total: total,
      contentType: source.contentType,
      stream: start >= total
          ? const Stream<List<int>>.empty()
          : reader.read(start, end),
    );
  }
}

final class _CachingEntry extends _Entry {
  _CachingEntry(this.download);

  final CachingDownload download;

  @override
  Future<ProxyBody?> open(({int start, int? end})? range) => download.open(range);
}

/// Загрузка upstream в `<cachePath>.part` с публикацией в кэш по завершении.
@visibleForTesting
class CachingDownload {
  CachingDownload({
    required HttpClient client,
    required this.uri,
    required this.headers,
    required this.cachePath,
    required this.pollInterval,
    required this.stallTimeout,
    required this.seekAheadBytes,
    required void Function(CachingDownload) onSettled,
  })  : _client = client,
        _onSettled = onSettled {
    // Ошибки доходят до читателей через reader / open(); сами future
    // наружу может никто не слушать.
    _ready.future.ignore();
    _completion.future.ignore();
  }

  final HttpClient _client;
  final Uri uri;
  final Map<String, String> headers;
  final String cachePath;
  final Duration pollInterval;
  final Duration stallTimeout;
  final int seekAheadBytes;
  final void Function(CachingDownload) _onSettled;

  /// Свой суффикс: ручная загрузка и кэширование плейлиста пишут в
  /// `<cachePath>.part` — общий файл обрезался бы вторым писателем.
  String get partPath => '$cachePath.stream.part';

  /// Ответ upstream получен: длина и тип известны (или загрузка упала).
  final Completer<void> _ready = Completer<void>();

  /// Финальный путь после публикации в кэш или ошибка загрузки.
  final Completer<String> _completion = Completer<String>();

  int? _total;
  String _contentType = 'application/octet-stream';
  int _written = 0;
  bool _finished = false;
  bool _published = false;
  bool _cancelled = false;
  bool _publishing = false;
  bool failed = false;

  static const int publishAttempts = 5;
  static const Duration publishRetryDelay = Duration(milliseconds: 250);
  int _readers = 0;
  HttpClientRequest? _request;
  GrowingFileReader? _reader;

  int get written => _written;
  bool get published => _published;
  int get readers => _readers;

  /// Публикация в кэш (или ошибка загрузки).
  Future<String> get completion => _completion.future;

  Future<void> start() async {
    RandomAccessFile? file;
    try {
      // Уже лежит в кэше (гонка с ручным скачиванием).
      if (await File(cachePath).exists()) {
        final length = await File(cachePath).length();
        _total = length;
        _contentType = audioContentTypeFor(
            p.extension(cachePath).replaceFirst('.', ''));
        _published = true;
        _completion.complete(cachePath);
        _reader = _newReader(length);
        _ready.complete();
        _onSettled(this);
        return;
      }

      final request = await _client.getUrl(uri);
      _request = request;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(stallTimeout);
      if (response.statusCode != HttpStatus.ok) {
        unawaited(response.drain<void>().catchError((_) {}));
        throw HttpException('upstream HTTP ${response.statusCode}', uri: uri);
      }
      _contentType = response.headers.contentType?.mimeType ??
          audioContentTypeFor(p.extension(cachePath).replaceFirst('.', ''));
      final total = response.contentLength;
      if (total <= 0) {
        // Без длины range-запросы не обслужить — отдаём upstream напрямую,
        // в кэш такой поток не пишем. Тело не дочитываем (drain скачал бы
        // весь трек впустую) — соединение обрывается.
        request.abort();
        unawaited(response.listen(null).cancel().catchError((_) {}));
        _ready.complete();
        failed = true;
        _completion.completeError(
            const HttpException('upstream did not report length'));
        _onSettled(this);
        return;
      }
      _total = total;
      await File(partPath).parent.create(recursive: true);
      file = await File(partPath).open(mode: FileMode.write);
      _reader = _newReader(total);
      _ready.complete();

      // Upstream без данных дольше stallTimeout считается зависшим: иначе
      // загрузка висела бы вечно и переиспользовалась повторными запросами.
      await for (final chunk in response.timeout(stallTimeout)) {
        if (_cancelled) break;
        await file.writeFrom(chunk);
        _written += chunk.length;
      }
      await file.close();
      file = null;
      if (_cancelled) throw const HttpException('cancelled');
      if (_written != total) {
        throw HttpException('upstream ended at $_written of $total bytes',
            uri: uri);
      }
      _finished = true;
      await _tryPublish();
    } catch (e) {
      await file?.close();
      failed = true;
      if (!_cancelled) _log('download $uri failed: $e');
      if (!_ready.isCompleted) _ready.completeError(e);
      if (!_completion.isCompleted) _completion.completeError(e);
      await _deletePart();
      _onSettled(this);
    }
  }

  GrowingFileReader _newReader(int total) {
    return GrowingFileReader(
      partPath: partPath,
      totalBytes: total,
      completion: _completion.future,
      pollInterval: pollInterval,
      stallTimeout: stallTimeout,
    );
  }

  Future<void> _deletePart() async {
    if (_readers > 0) return;
    try {
      final part = File(partPath);
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  /// Rename `.part` → кэш, когда закрыты писатель и все читатели.
  ///
  /// Сразу после закрытия файл может держать антивирус / индексатор
  /// (errno 32) — несколько повторов; если так и не вышло, загрузка
  /// считается неудачной, а не висит неопубликованной до конца сессии.
  Future<void> _tryPublish() async {
    if (!_finished || _published || _publishing || _readers > 0) return;
    _publishing = true;
    try {
      Object? lastError;
      for (var attempt = 0; attempt < publishAttempts; attempt++) {
        if (attempt > 0) await Future<void>.delayed(publishRetryDelay);
        // Пока ждали, снова открыли читателя — опубликует его release().
        if (_readers > 0) return;
        try {
          final target = File(cachePath);
          if (await target.exists()) await target.delete();
          await File(partPath).rename(cachePath);
          _published = true;
          _completion.complete(cachePath);
          _log('cached $cachePath ($_written bytes)');
          _onSettled(this);
          return;
        } catch (e) {
          lastError = e;
        }
      }
      _log('publish $cachePath failed: $lastError');
      failed = true;
      if (!_completion.isCompleted) {
        _completion.completeError(lastError ?? 'publish failed');
      }
      await _deletePart();
      _onSettled(this);
    } finally {
      _publishing = false;
    }
  }

  /// Отменяет незавершённую загрузку, если её никто не читает.
  void cancelIfIdle() {
    if (_readers == 0 && !_finished) cancel();
  }

  void cancel() {
    if (_finished || failed) return;
    _cancelled = true;
    _request?.abort(const HttpException('cancelled'));
  }

  Future<ProxyBody?> open(({int start, int? end})? range) async {
    try {
      await _ready.future;
    } catch (_) {
      return null;
    }
    final total = _total;
    final start = range?.start ?? 0;
    if (total == null) {
      if (start != 0) return null;
      final direct = await _upstream(null);
      if (direct == null) return null;
      return (
        start: 0,
        end: null,
        total: null,
        contentType: _contentType,
        stream: direct,
      );
    }
    final end = math.min(range?.end ?? total, total);
    if (start >= total) {
      return (
        start: start,
        end: total,
        total: total,
        contentType: _contentType,
        stream: const Stream<List<int>>.empty(),
      );
    }
    if (!_published && !_finished && start > _written + seekAheadBytes) {
      final direct = await _upstream((start: start, end: end));
      if (direct != null) {
        return (
          start: start,
          end: end,
          total: total,
          contentType: _contentType,
          stream: direct,
        );
      }
    }
    return (
      start: start,
      end: end,
      total: total,
      contentType: _contentType,
      stream: _tracked(_reader!.read(start, end)),
    );
  }

  /// Отдельный запрос в upstream мимо кэша: seek далеко вперёд.
  Future<Stream<List<int>>?> _upstream(({int start, int end})? range) async {
    try {
      final request = await _client.getUrl(uri);
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) {
        request.headers.set(
            HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end - 1}');
      }
      final response = await request.close();
      if (response.statusCode == HttpStatus.partialContent) return response;
      if (response.statusCode == HttpStatus.ok) {
        // Upstream проигнорировал Range — пропускаем начало сами.
        return range == null
            ? response
            : _slice(response, range.start, range.end - range.start);
      }
      unawaited(response.drain<void>().catchError((_) {}));
      return null;
    } catch (e) {
      _log('direct upstream $uri failed: $e');
      return null;
    }
  }

  static Stream<List<int>> _slice(Stream<List<int>> s, int skip, int take) async* {
    var toSkip = skip;
    var left = take;
    await for (final chunk in s) {
      var c = chunk;
      if (toSkip > 0) {
        if (c.length <= toSkip) {
          toSkip -= c.length;
          continue;
        }
        c = c.sublist(toSkip);
        toSkip = 0;
      }
      if (c.length >= left) {
        yield c.sublist(0, left);
        return;
      }
      left -= c.length;
      yield c;
    }
  }

  /// Считает открытых читателей `.part`: публикация ждёт, пока они закроются.
  Stream<List<int>> _tracked(Stream<List<int>> inner) {
    var released = false;
    StreamSubscription<List<int>>? sub;
    late final StreamController<List<int>> controller;
    void release() {
      if (released) return;
      released = true;
      _readers--;
      if (_readers == 0) {
        if (_finished) unawaited(_tryPublish());
        if (failed) unawaited(_deletePart());
      }
    }

    controller = StreamController<List<int>>(
      onListen: () {
        _readers++;
        sub = inner.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            release();
            unawaited(controller.close());
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        await sub?.cancel();
        release();
      },
    );
    return controller.stream;
  }
}
