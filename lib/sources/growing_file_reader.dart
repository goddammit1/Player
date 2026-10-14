// lib/sources/growing_file_reader.dart
//
// Чтение файла, который ещё дописывается (стриминг во время загрузки).
//
// Писатель (нативная загрузка Soulseek или кэширующий прокси) пишет файл
// последовательно в `.part` и по завершении переименовывает его в финальный.
// Читатель отдаёт уже записанные байты и ждёт прироста файла, пока загрузка
// не завершится или не упадёт. Общий для мобильного
// [SoulseekStreamAudioSource] и десктопного локального прокси.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Открытые читателями файлы. На Windows файл, открытый Dart на чтение,
/// нельзя переименовать или удалить (нет FILE_SHARE_DELETE), поэтому
/// публикация растущего файла (rename `.part` → final) ждёт, пока читатели
/// его закроют.
class FileReadLeases {
  FileReadLeases._();

  static final Map<String, int> _open = {};
  static final Map<String, List<Completer<void>>> _idleWaiters = {};

  static String _key(String path) => p.canonicalize(path);

  static void acquire(String path) {
    final key = _key(path);
    _open[key] = (_open[key] ?? 0) + 1;
  }

  static void release(String path) {
    final key = _key(path);
    final count = (_open[key] ?? 1) - 1;
    if (count > 0) {
      _open[key] = count;
      return;
    }
    _open.remove(key);
    final waiters = _idleWaiters.remove(key);
    if (waiters == null) return;
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
  }

  static bool isOpen(String path) => _open.containsKey(_key(path));

  /// Завершается, когда [path] не открыт ни одним читателем.
  static Future<void> whenIdle(String path) {
    final key = _key(path);
    if (!_open.containsKey(key)) return Future<void>.value();
    final waiter = Completer<void>();
    (_idleWaiters[key] ??= []).add(waiter);
    return waiter.future;
  }
}

/// Ошибка чтения растущего файла: загрузка зависла или файл оказался
/// короче заявленного.
class GrowingFileException implements Exception {
  const GrowingFileException(this.code, this.message, {this.retryable = false});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'GrowingFileException($code): $message';
}

/// Создаёт ошибку чтения; источник может подставить свой тип исключения.
typedef GrowingFileErrorFactory = Object Function(
  String code,
  String message, {
  bool retryable,
});

Object _defaultError(String code, String message, {bool retryable = false}) =>
    GrowingFileException(code, message, retryable: retryable);

class GrowingFileReader {
  GrowingFileReader({
    required this.partPath,
    required this.totalBytes,
    required Future<String> completion,
    this.pollInterval = const Duration(milliseconds: 200),
    this.stallTimeout = const Duration(seconds: 45),
    GrowingFileErrorFactory errorFactory = _defaultError,
  }) : _errorFactory = errorFactory {
    completion.then<void>(
      (path) => _completedPath = path,
      onError: (Object e) => _failure = e,
    );
  }

  /// Путь `.part`, который пишет загрузка.
  final String partPath;

  /// Заявленный размер файла.
  final int totalBytes;

  /// Как часто проверять прирост файла, когда записанные байты кончились.
  final Duration pollInterval;

  /// Сколько ждать прироста файла, прежде чем считать загрузку зависшей.
  final Duration stallTimeout;

  final GrowingFileErrorFactory _errorFactory;

  static const int chunkSize = 64 * 1024;

  /// Финальный путь после успешной загрузки (rename `.part` → final).
  String? _completedPath;

  /// Ошибка загрузки: обрывает все текущие и будущие чтения.
  Object? _failure;

  String? get completedPath => _completedPath;

  /// Байты [from, to) файла; `to` ограничивается [totalBytes].
  Stream<List<int>> read(int from, [int? to]) {
    final end = math.min(to ?? totalBytes, totalBytes);
    if (from < 0 || from > end) {
      throw RangeError.range(from, 0, end, 'start');
    }
    return _TailReader(this, from, end).stream;
  }

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) throw failure;
  }

  void _throwIfStalled(Stopwatch stall) {
    if (stall.elapsed < stallTimeout) return;
    throw _errorFactory(
      'STREAM_STALLED',
      'Download made no progress',
      retryable: true,
    );
  }
}

/// Одно чтение: файл от [_from] до [_to] (исключая), с ожиданием байтов,
/// которые ещё не записаны.
///
/// Построен на [StreamController], а не на `async*`: генератор узнаёт об
/// отмене подписки только на следующем `yield`, и читатель, ждущий данных,
/// держал бы файл открытым до таймаута. Здесь отмена будит ожидание сразу.
class _TailReader {
  _TailReader(this._reader, this._from, this._to);

  final GrowingFileReader _reader;
  final int _from;
  final int _to;

  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(onListen: _start, onCancel: _cancel);

  bool _cancelled = false;
  Completer<void>? _wake;
  Future<void>? _loop;

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
    final timer = Timer(_reader.pollInterval, () {
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
      FileReadLeases.acquire(file.path);
      await file.setPosition(_from);
      var position = _from;
      while (!_cancelled && position < _to) {
        _reader._throwIfFailed();
        // Флаг снимается ДО чтения: если загрузка завершилась уже после
        // пустого чтения, последние байты могли дописаться между ними.
        final completedBeforeRead = _reader._completedPath != null;
        final chunk = await file.read(
          math.min(GrowingFileReader.chunkSize, _to - position),
        );
        if (chunk.isNotEmpty) {
          position += chunk.length;
          stall.reset();
          if (!_cancelled) _controller.add(chunk);
          continue;
        }
        if (completedBeforeRead) {
          throw _reader._errorFactory(
            'STREAM_TRUNCATED',
            'Downloaded file ended at $position of ${_reader.totalBytes} bytes',
          );
        }
        _reader._throwIfStalled(stall);
        await _sleep();
      }
    } catch (e, st) {
      if (!_cancelled) _controller.addError(e, st);
    } finally {
      if (file != null) {
        try {
          await file.close();
        } finally {
          FileReadLeases.release(file.path);
        }
      }
      if (!_cancelled) unawaited(_controller.close());
    }
  }

  /// Открывает `.part`, а после завершения загрузки — финальный файл.
  /// `.part` может ещё не существовать (загрузка не начала писать) или уже
  /// быть переименован — тогда ждём. null — подписку отменили.
  Future<RandomAccessFile?> _open(Stopwatch stall) async {
    while (!_cancelled) {
      _reader._throwIfFailed();
      final completedPath = _reader._completedPath;
      if (completedPath != null) return File(completedPath).open();
      try {
        return await File(_reader.partPath).open();
      } on FileSystemException {
        _reader._throwIfStalled(stall);
        await _sleep();
      }
    }
    return null;
  }
}
