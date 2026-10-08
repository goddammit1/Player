// Тесты SoulseekStreamAudioSource: чтение растущего .part файла.
//
// Нативная загрузка эмулируется дописыванием байтов во временный файл;
// завершение/ошибка загрузки — через Completer, который в проде получает
// результат SoulseekSource._waitForDownloadComplete.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_stream_audio_source.dart';

List<int> _bytes(int from, int count) =>
    List<int>.generate(count, (i) => (from + i) % 256);

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  late Directory dir;
  late File part;
  late Completer<String> completion;

  SoulseekStreamAudioSource createSource({
    int totalBytes = 1000,
    Duration stallTimeout = const Duration(seconds: 5),
  }) {
    return SoulseekStreamAudioSource(
      partPath: part.path,
      totalBytes: totalBytes,
      contentType: 'audio/mpeg',
      completion: completion.future,
      pollInterval: const Duration(milliseconds: 5),
      stallTimeout: stallTimeout,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slsk_stream_test');
    part = File('${dir.path}/abc.part');
    completion = Completer<String>();
  });

  tearDown(() async {
    if (!completion.isCompleted) completion.complete(part.path);
    await dir.delete(recursive: true);
  });

  test('full request reports source length and offset 0', () async {
    await part.writeAsBytes(_bytes(0, 1000));
    final source = createSource();

    final response = await source.request();

    expect(response.sourceLength, 1000);
    expect(response.contentLength, 1000);
    expect(response.offset, 0);
    expect(response.contentType, 'audio/mpeg');
    expect(await _collect(response.stream), _bytes(0, 1000));
  });

  test('range request returns only requested bytes', () async {
    await part.writeAsBytes(_bytes(0, 1000));
    final source = createSource();

    final response = await source.request(100, 300);

    expect(response.offset, 100);
    expect(response.contentLength, 200);
    expect(await _collect(response.stream), _bytes(100, 200));
  });

  test('end beyond total size is clamped', () async {
    await part.writeAsBytes(_bytes(0, 1000));
    final source = createSource();

    final response = await source.request(900, 5000);

    expect(response.contentLength, 100);
    expect(await _collect(response.stream), _bytes(900, 100));
  });

  test('waits for bytes that are not written yet', () async {
    await part.writeAsBytes(_bytes(0, 100));
    final source = createSource();

    final response = await source.request();
    final result = _collect(response.stream);

    // Дописываем остаток порциями, как это делает C# bridge.
    for (var offset = 100; offset < 1000; offset += 300) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await part.writeAsBytes(_bytes(offset, 300), mode: FileMode.append);
    }

    expect(await result, _bytes(0, 1000));
  });

  test('waits for the part file to appear', () async {
    final source = createSource();

    final response = await source.request();
    final result = _collect(response.stream);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    await part.writeAsBytes(_bytes(0, 1000));

    expect(await result, _bytes(0, 1000));
  });

  test('reads the final file after download completed and renamed', () async {
    final finalFile = File('${dir.path}/abc.mp3');
    await finalFile.writeAsBytes(_bytes(0, 1000));
    completion.complete(finalFile.path);
    final source = createSource();
    await Future<void>.delayed(Duration.zero);

    final response = await source.request(500);

    expect(await _collect(response.stream), _bytes(500, 500));
  });

  test('download failure ends the stream with the error', () async {
    await part.writeAsBytes(_bytes(0, 100));
    final source = createSource();

    final response = await source.request();
    final result = _collect(response.stream);
    completion.completeError(
      const SoulseekException('DOWNLOAD_FAILED', 'peer went offline'),
    );

    await expectLater(
      result,
      throwsA(isA<SoulseekException>()
          .having((e) => e.code, 'code', 'DOWNLOAD_FAILED')),
    );
  });

  test('no progress longer than stallTimeout ends the stream', () async {
    await part.writeAsBytes(_bytes(0, 100));
    final source = createSource(
      stallTimeout: const Duration(milliseconds: 50),
    );

    final response = await source.request();

    await expectLater(
      _collect(response.stream),
      throwsA(isA<SoulseekException>()
          .having((e) => e.code, 'code', 'STREAM_STALLED')),
    );
  });

  test('completed download shorter than declared size is an error', () async {
    await part.writeAsBytes(_bytes(0, 600));
    completion.complete(part.path);
    final source = createSource();
    await Future<void>.delayed(Duration.zero);

    final response = await source.request();

    await expectLater(
      _collect(response.stream),
      throwsA(isA<SoulseekException>()
          .having((e) => e.code, 'code', 'STREAM_TRUNCATED')),
    );
  });

  test('cancelling the subscription releases the file', () async {
    await part.writeAsBytes(_bytes(0, 100));
    final source = createSource();

    final response = await source.request();
    final firstChunk = Completer<void>();
    final sub = response.stream.listen((_) {
      if (!firstChunk.isCompleted) firstChunk.complete();
    });
    await firstChunk.future;
    await sub.cancel();

    // Файл закрыт: на Windows удаление открытого файла упало бы.
    await part.delete();
    expect(await part.exists(), isFalse);
  });

  test('cancelling while waiting for data releases the file promptly',
      () async {
    await part.writeAsBytes(_bytes(0, 100));
    final source = SoulseekStreamAudioSource(
      partPath: part.path,
      totalBytes: 1000,
      contentType: 'audio/mpeg',
      completion: completion.future,
      // Длинный интервал: читатель гарантированно «спит» в момент отмены.
      pollInterval: const Duration(seconds: 2),
    );

    final response = await source.request();
    final firstChunk = Completer<void>();
    final sub = response.stream.listen((_) {
      if (!firstChunk.isCompleted) firstChunk.complete();
    });
    await firstChunk.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel().timeout(const Duration(milliseconds: 500));

    await part.delete();
    expect(await part.exists(), isFalse);
  });

  test('start beyond total size is rejected', () async {
    final source = createSource();

    expect(() => source.request(1001), throwsA(isA<RangeError>()));
  });

  group('contentTypeFor', () {
    test('maps common audio extensions', () {
      expect(SoulseekStreamAudioSource.contentTypeFor('mp3'), 'audio/mpeg');
      expect(SoulseekStreamAudioSource.contentTypeFor('FLAC'), 'audio/flac');
      expect(SoulseekStreamAudioSource.contentTypeFor('ogg'), 'audio/ogg');
      expect(SoulseekStreamAudioSource.contentTypeFor('opus'), 'audio/ogg');
      expect(SoulseekStreamAudioSource.contentTypeFor('m4a'), 'audio/mp4');
      expect(SoulseekStreamAudioSource.contentTypeFor('wav'), 'audio/wav');
    });

    test('falls back to octet-stream for unknown extensions', () {
      expect(
        SoulseekStreamAudioSource.contentTypeFor('dat'),
        'application/octet-stream',
      );
    });
  });
}
