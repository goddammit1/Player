// Учёт открытых читателей растущего файла: публикация `.part` на Windows
// ждёт, пока прокси закроет файл.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/growing_file_reader.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('leases_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('читатель держит лизу, пока файл открыт', () async {
    final part = File('${tmp.path}${Platform.pathSeparator}a.part')
      ..writeAsBytesSync(List.filled(10, 7));
    final completion = Completer<String>();
    final reader = GrowingFileReader(
      partPath: part.path,
      totalBytes: 20,
      completion: completion.future,
      pollInterval: const Duration(milliseconds: 10),
    );

    final chunks = <int>[];
    final sub = reader.read(0).listen(chunks.addAll);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chunks, hasLength(10));
    expect(FileReadLeases.isOpen(part.path), isTrue);

    var idle = false;
    unawaited(FileReadLeases.whenIdle(part.path).then((_) => idle = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(idle, isFalse);

    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(FileReadLeases.isOpen(part.path), isFalse);
    expect(idle, isTrue);
  });

  test('whenIdle для незанятого файла завершается сразу', () async {
    await FileReadLeases.whenIdle('${tmp.path}${Platform.pathSeparator}none')
        .timeout(const Duration(milliseconds: 100));
  });
}
