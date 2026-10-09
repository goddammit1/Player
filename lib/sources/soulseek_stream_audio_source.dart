// lib/sources/soulseek_stream_audio_source.dart
//
// Стриминг Soulseek: воспроизведение во время загрузки.
//
// C# bridge пишет файл последовательно в `<cacheKey>.part` и по завершении
// делает atomic rename в `<cacheKey>.<ext>`. Этот AudioSource отдаёт плееру
// (через локальный прокси just_audio) уже записанные байты `.part` и ждёт
// прироста файла, пока загрузка не завершится или не упадёт.
//
// Открытый дескриптор переживает rename (Linux/Android), поэтому уже идущее
// чтение не прерывается; новые range-запросы после завершения читают
// финальный файл.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

import 'soulseek_models.dart';

class SoulseekStreamAudioSource extends StreamAudioSource {
  /// Путь `.part`, который пишет нативная загрузка.
  final String partPath;

  /// Заявленный пиром размер файла: длина источника для плеера.
  final int totalBytes;

  final String contentType;

  /// Как часто проверять прирост файла, когда записанные байты кончились.
  final Duration pollInterval;

  /// Сколько ждать прироста файла, прежде чем считать загрузку зависшей.
  /// ExoPlayer рвёт соединение после 8 с без байтов и переподключается,
  /// сдаваясь примерно через 40 с без прогресса — дольше ждать бессмысленно,
  /// а брошенные читатели закрываются по этому таймауту.
  final Duration stallTimeout;

  static const int _chunkSize = 64 * 1024;

  /// Финальный путь после успешной загрузки (rename `.part` → final).
  String? _completedPath;

  /// Ошибка загрузки: обрывает все текущие и будущие чтения.
  Object? _failure;

  SoulseekStreamAudioSource({
    required this.partPath,
    required this.totalBytes,
    required this.contentType,
    required Future<String> completion,
    this.pollInterval = const Duration(milliseconds: 200),
    this.stallTimeout = const Duration(seconds: 45),
    super.tag,
  }) {
    completion.then<void>(
      (path) => _completedPath = path,
      onError: (Object e) => _failure = e,
    );
  }

  /// MIME-тип по расширению файла Soulseek.
  static String contentTypeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'm4a':
      case 'aac':
      case 'alac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = math.min(end ?? totalBytes, totalBytes);
    if (from < 0 || from > to) {
      throw RangeError.range(from, 0, to, 'start');
    }
    return StreamAudioResponse(
      sourceLength: totalBytes,
      contentLength: to - from,
      offset: from,
      contentType: contentType,
      stream: _read(from, to),
    );
  }

  Stream<List<int>> _read(int from, int to) =>
      _PartTailReader(this, from, to).stream;

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) throw failure;
  }

  void _throwIfStalled(Stopwatch stall) {
    if (stall.elapsed < stallTimeout) return;
    throw const SoulseekException(
      'STREAM_STALLED',
      'Download made no progress',
      retryable: true,
    );
  }
}

/// Один range-запрос плеера: читает `.part` от [from] до [to] (исключая),
/// дожидаясь байтов, которые ещё не записаны.
///
/// Построен на [StreamController], а не на `async*`: генератор узнаёт об
/// отмене подписки только на следующем `yield`, и читатель, ждущий данных,
/// держал бы файл открытым до таймаута. Здесь отмена будит ожидание сразу.
class _PartTailReader {
  final SoulseekStreamAudioSource _source;
  final int _from;
  final int _to;

  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(onListen: _start, onCancel: _cancel);

  bool _cancelled = false;
  Completer<void>? _wake;
  Future<void>? _loop;

  _PartTailReader(this._source, this._from, this._to);

  Stream<List<int>> get stream => _controller.stream;

  void _start() => _loop = _run();

  /// Будит ожидание и возвращает future цикла: `cancel()` подписки
  /// завершается, когда файл уже закрыт.
  Future<void>? _cancel() {
    _cancelled = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    return _loop;
  }

  Future<void> _sleep() {
    final wake = Completer<void>();
    _wake = wake;
    final timer = Timer(_source.pollInterval, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  Future<void> _run() async {
    final stall = Stopwatch()..start();
    RandomAccessFile? file;
    try {
      file = await _open(stall);
      if (file == null) return;
      await file.setPosition(_from);
      var position = _from;
      while (!_cancelled && position < _to) {
        _source._throwIfFailed();
        // Флаг снимается ДО чтения: если загрузка завершилась уже после
        // пустого чтения, последние байты могли дописаться между ними.
        final completedBeforeRead = _source._completedPath != null;
        final chunk = await file.read(
          math.min(SoulseekStreamAudioSource._chunkSize, _to - position),
        );
        if (chunk.isNotEmpty) {
          position += chunk.length;
          stall.reset();
          if (!_cancelled) _controller.add(chunk);
          continue;
        }
        if (completedBeforeRead) {
          throw SoulseekException(
            'STREAM_TRUNCATED',
            'Downloaded file ended at $position of ${_source.totalBytes} bytes',
          );
        }
        _source._throwIfStalled(stall);
        await _sleep();
      }
    } catch (e, st) {
      if (!_cancelled) _controller.addError(e, st);
    } finally {
      await file?.close();
      if (!_cancelled) unawaited(_controller.close());
    }
  }

  /// Открывает `.part`, а после завершения загрузки — финальный файл.
  /// `.part` может ещё не существовать (пир не начал отдавать) или уже
  /// быть переименован — тогда ждём. null — подписку отменили.
  Future<RandomAccessFile?> _open(Stopwatch stall) async {
    while (!_cancelled) {
      _source._throwIfFailed();
      final completedPath = _source._completedPath;
      if (completedPath != null) return File(completedPath).open();
      try {
        return await File(_source.partPath).open();
      } on FileSystemException {
        _source._throwIfStalled(stall);
        await _sleep();
      }
    }
    return null;
  }
}
