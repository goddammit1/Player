// lib/core/windows_update_installer.dart
//
// Установка обновления на Windows из zip GitHub-релиза (этап 4.3 плана
// паритета). zip — это содержимое папки Release (`tools/build_windows.ps1
// -Zip`): player.exe, DLL Flutter/media_kit, мост Soulseek с .NET runtime.
//
// 1. Распаковка во временный каталог (Expand-Archive) — ошибки видны
//    пользователю до выхода из приложения.
// 2. Отсоединённый PowerShell-скрипт ждёт выхода player.exe, копирует
//    файлы поверх папки приложения (robocopy) и перезапускает его.
// 3. Приложение закрывается штатно (сохранение сессии в didRequestAppExit).
//
// Данные пользователя после 4.1 лежат вне папки с exe (`%APPDATA%`,
// `%LOCALAPPDATA%`), поэтому замена файлов их не задевает. Если папка
// приложения недоступна на запись (Program Files без прав администратора) —
// [InstallOutcome.manualRequired]: UI предлагает страницу релиза.

import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);
typedef DetachedStarter = Future<void> Function(
    String executable, List<String> arguments);

class WindowsUpdateInstaller {
  WindowsUpdateInstaller({
    String? appDir,
    Future<Directory> Function()? tempDir,
    ProcessRunner? run,
    DetachedStarter? startDetached,
    Future<void> Function()? exitApp,
    bool? releaseMode,
  })  : appDir = appDir ?? p.dirname(Platform.resolvedExecutable),
        _tempDir = tempDir ?? getTemporaryDirectory,
        _run = run ?? Process.run,
        _startDetached = startDetached ?? _defaultStartDetached,
        _exitApp = exitApp ?? _defaultExitApp,
        _releaseMode = releaseMode ?? kReleaseMode;

  /// Папка установленного приложения (рядом с player.exe).
  final String appDir;
  final Future<Directory> Function() _tempDir;
  final ProcessRunner _run;
  final DetachedStarter _startDetached;
  final Future<void> Function() _exitApp;
  final bool _releaseMode;

  static const exeName = 'player.exe';

  /// Распаковывает [zipPath], запускает скрипт замены и закрывает
  /// приложение. Бросает исключение, если пакет не распаковался или в нём
  /// нет player.exe — установленная версия при этом не тронута.
  Future<InstallOutcome> install(String zipPath) async {
    if (!_releaseMode) {
      // Debug-сборка из build\…\Debug: поверх неё release-файлы не кладём.
      throw UnsupportedError(
        'In-app update is available only in release builds.',
      );
    }
    if (!await isAppDirWritable()) return InstallOutcome.manualRequired;

    final temp = await _tempDir();
    final staging = p.join(temp.path, 'player-update-staging');
    // Остатки прошлой попытки не должны сойти за распакованный пакет.
    final stagingDir = Directory(staging);
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    final script = File(p.join(temp.path, 'player-update.ps1'));
    await script.writeAsString(updateScript);

    final extract = await _run('powershell.exe', [
      ..._psArgs(script.path),
      '-Mode', 'extract',
      '-Zip', zipPath,
      '-Staging', staging,
    ]);
    if (extract.exitCode != 0) {
      throw StateError(
        'Could not unpack the update: ${'${extract.stderr}'.trim()}',
      );
    }
    final root = findPackageRoot(Directory(staging));
    if (root == null) {
      throw StateError('The update package does not contain $exeName.');
    }

    await _startDetached('powershell.exe', [
      ..._psArgs(script.path),
      '-Mode', 'apply',
      '-Source', root.path,
      '-Target', appDir,
      '-Staging', staging,
      '-ProcessId', '$pid',
      '-Log', p.join(temp.path, 'player-update.log'),
    ]);
    await _exitApp();
    return InstallOutcome.restarting;
  }

  /// Можно ли писать в папку приложения (Program Files — обычно нельзя).
  Future<bool> isAppDirWritable() async {
    final probe = File(p.join(appDir, '.player-update-check'));
    try {
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } on FileSystemException catch (_) {
      return false;
    }
  }

  /// Каталог с player.exe внутри распакованного пакета: корень или
  /// единственная вложенная папка (zip, собранный вручную вместе с папкой).
  @visibleForTesting
  static Directory? findPackageRoot(Directory staging) {
    if (File(p.join(staging.path, exeName)).existsSync()) return staging;
    if (!staging.existsSync()) return null;
    final nested = staging
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where((d) => File(p.join(d.path, exeName)).existsSync())
        .toList();
    return nested.length == 1 ? nested.single : null;
  }

  /// Открывает страницу релиза в браузере по умолчанию.
  static Future<void> openInBrowser(String url) async {
    await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached);
  }

  static List<String> _psArgs(String script) => [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script,
      ];

  static Future<void> _defaultStartDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments,
        mode: ProcessStartMode.detached);
  }

  /// Штатный выход: didRequestAppExit сохраняет сессию и ставит загрузки
  /// Soulseek на паузу. `exit(0)` — страховка, если движок не закрылся.
  static Future<void> _defaultExitApp() async {
    try {
      await ServicesBinding.instance
          .exitApplication(AppExitType.cancelable)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    exit(0);
  }

  /// Скрипт обновления. Только ASCII: Windows PowerShell 5.1 читает .ps1
  /// без BOM в ANSI-кодировке. Пути передаются аргументами (-File), поэтому
  /// кириллица в имени пользователя не мешает.
  @visibleForTesting
  static const String updateScript = r'''
# Player updater, generated by the app (lib/core/windows_update_installer.dart).
param(
    [Parameter(Mandatory = $true)][ValidateSet('extract', 'apply')][string]$Mode,
    [string]$Zip,
    [string]$Staging,
    [string]$Source,
    [string]$Target,
    [int]$ProcessId = 0,
    [string]$Log
)
$ErrorActionPreference = 'Stop'

if ($Mode -eq 'extract') {
    if (Test-Path -LiteralPath $Staging) {
        Remove-Item -LiteralPath $Staging -Recurse -Force
    }
    $ProgressPreference = 'SilentlyContinue'
    Expand-Archive -LiteralPath $Zip -DestinationPath $Staging -Force
    exit 0
}

function Write-Log([string]$Message) {
    if ($Log) {
        Add-Content -LiteralPath $Log -Value ('{0:u} {1}' -f (Get-Date), $Message)
    }
}

$exe = Join-Path $Target 'player.exe'
try {
    if ($ProcessId -gt 0) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.WaitForExit(120000)) {
            # The app did not close: do not touch locked files, keep it running.
            Write-Log "player.exe (pid $ProcessId) did not exit, update aborted"
            exit 1
        }
    }
    # robocopy exit codes 0-7 mean success; retries cover DLLs that are
    # still being released right after the process exit.
    $null = robocopy $Source $Target /E /R:10 /W:1 /NFL /NDL /NJH /NJS /NP
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        Write-Log "robocopy failed with exit code $code"
    } else {
        Write-Log "updated $Target"
        Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "update failed: $_"
}
Start-Process -FilePath $exe -WorkingDirectory $Target
''';
}
