// Экспорт бэкапа на десктопе (этап 4.2): «Сохранить как…» вместо
// share-sheet. Диалог подменён через saveFileDialogOverride.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:player/core/backup/playlist_backup.dart';
import 'package:player/models/playlist.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('player_export_');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    saveFileDialogOverride = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final playlist = Playlist(
    id: 'p1',
    name: 'Road: trip?',
    tracks: const [],
    createdAt: DateTime(2026, 1, 1),
  );

  test('пишет файл по выбранному пути и дописывает .json', () async {
    String? suggested;
    saveFileDialogOverride = (name) async {
      suggested = name;
      return p.join(dir.path, 'my backup');
    };

    expect(await PlaylistBackup.exportAndShare([playlist]), isTrue);

    // Имя плейлиста очищено от запрещённых в Windows символов.
    expect(suggested, startsWith('Road_ trip__'));
    expect(suggested, endsWith('.json'));
    final file = File(p.join(dir.path, 'my backup.json'));
    expect(file.existsSync(), isTrue);
    final restored = PlaylistBackup.decode(file.readAsStringSync());
    expect(restored.single.name, 'Road: trip?');
  });

  test('отмена диалога — false, файл не создаётся', () async {
    saveFileDialogOverride = (_) async => null;

    expect(await PlaylistBackup.exportAndShare([playlist]), isFalse);
    expect(dir.listSync(), isEmpty);
  });
}
