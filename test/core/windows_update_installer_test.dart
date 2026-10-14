// Юнит-тесты WindowsUpdateInstaller (этап 4.3): процессы, выход из
// приложения и временный каталог подменены — PowerShell не запускается.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:player/core/update_service.dart';
import 'package:player/core/windows_update_installer.dart';

void main() {
  late Directory root;
  late Directory appDir;
  late Directory temp;

  setUp(() {
    root = Directory.systemTemp.createTempSync('player_updater_');
    appDir = Directory(p.join(root.path, 'app'))..createSync();
    temp = Directory(p.join(root.path, 'temp'))..createSync();
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Распаковка-заглушка: кладёт пакет в -Staging.
  Future<ProcessResult> Function(String, List<String>) fakeExtract({
    bool withExe = true,
    int exitCode = 0,
  }) =>
      (exe, args) async {
        final staging = args[args.indexOf('-Staging') + 1];
        final file = File(
            p.join(staging, withExe ? 'player.exe' : 'readme.txt'));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('new');
        return ProcessResult(1, exitCode, '', exitCode == 0 ? '' : 'boom');
      };

  test('распаковывает, запускает скрипт замены и закрывает приложение',
      () async {
    List<String>? started;
    var exited = false;
    final installer = WindowsUpdateInstaller(
      appDir: appDir.path,
      tempDir: () async => temp,
      run: fakeExtract(),
      startDetached: (exe, args) async => started = args,
      exitApp: () async => exited = true,
      releaseMode: true,
    );

    final outcome = await installer.install(p.join(temp.path, 'u.zip'));

    expect(outcome, InstallOutcome.restarting);
    expect(exited, isTrue);
    expect(started, isNotNull);
    String arg(String name) => started![started!.indexOf(name) + 1];
    expect(arg('-Mode'), 'apply');
    expect(arg('-Target'), appDir.path);
    expect(arg('-Source'), p.join(temp.path, 'player-update-staging'));
    expect(arg('-ProcessId'), '$pid');
    expect(File(p.join(temp.path, 'player-update.ps1')).existsSync(), isTrue);
  });

  test('папка приложения недоступна на запись — manualRequired', () async {
    var ran = false;
    final installer = WindowsUpdateInstaller(
      appDir: p.join(root.path, 'missing'),
      tempDir: () async => temp,
      run: (exe, args) async {
        ran = true;
        return ProcessResult(1, 0, '', '');
      },
      startDetached: (exe, args) async {},
      exitApp: () async {},
      releaseMode: true,
    );

    expect(await installer.install('u.zip'), InstallOutcome.manualRequired);
    expect(ran, isFalse);
  });

  test('ошибка распаковки или пакет без player.exe — без выхода', () async {
    var exited = false;
    WindowsUpdateInstaller make(
            Future<ProcessResult> Function(String, List<String>) run) =>
        WindowsUpdateInstaller(
          appDir: appDir.path,
          tempDir: () async => temp,
          run: run,
          startDetached: (exe, args) async {},
          exitApp: () async => exited = true,
          releaseMode: true,
        );

    await expectLater(
      make(fakeExtract(exitCode: 1)).install('u.zip'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      make(fakeExtract(withExe: false)).install('u.zip'),
      throwsA(isA<StateError>()),
    );
    expect(exited, isFalse);
  });

  test('debug-сборка не обновляется', () async {
    final installer = WindowsUpdateInstaller(
      appDir: appDir.path,
      releaseMode: false,
    );
    await expectLater(
      installer.install('u.zip'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('findPackageRoot: корень или единственная вложенная папка', () {
    final flat = Directory(p.join(root.path, 'flat'))..createSync();
    File(p.join(flat.path, 'player.exe')).writeAsStringSync('');
    expect(WindowsUpdateInstaller.findPackageRoot(flat)?.path, flat.path);

    final nested = Directory(p.join(root.path, 'nested'));
    final inner = Directory(p.join(nested.path, 'Release'))
      ..createSync(recursive: true);
    File(p.join(inner.path, 'player.exe')).writeAsStringSync('');
    expect(WindowsUpdateInstaller.findPackageRoot(nested)?.path, inner.path);

    final empty = Directory(p.join(root.path, 'empty'))..createSync();
    expect(WindowsUpdateInstaller.findPackageRoot(empty), isNull);
  });

  test('скрипт обновления — только ASCII (PowerShell 5.1 читает .ps1 в ANSI)',
      () {
    expect(
      WindowsUpdateInstaller.updateScript.codeUnits.every((c) => c < 128),
      isTrue,
    );
  });
}
