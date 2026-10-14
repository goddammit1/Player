# Release-sborka Windows (player.exe) s GENIUS_TOKEN iz env.json (--dart-define-from-file).
# Analogichno tools/build_release.ps1 dlya APK. Vse dopolnitelnye argumenty
# probrasyvayutsya v flutter build (napr. --debug, --dart-define=X=y).
# Flag -Zip pakuet papku s ispolnyaemym failom v build\player-windows-x64.zip.
# Most Soulseek (.NET, papka soulseek\) sobiraetsya CMake-shagom; nuzhen .NET 9 SDK.
# NOTE: derzhat etot fayl ASCII-only. Windows PowerShell 5.1 chitaet .ps1 kak
# ANSI, poetomu ne-ASCII simvoly bez BOM lomayut parsering (kak v install_release.ps1).
param(
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $root 'env.json'

if (-not (Test-Path $envFile)) {
    Write-Error "env.json not found: $envFile. Copy env.json.example -> env.json and paste your Genius Client Access Token."
    exit 1
}

$config = Get-Content $envFile -Raw | ConvertFrom-Json
$token = [string]$config.GENIUS_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or $token -eq 'PASTE_GENIUS_TOKEN_HERE') {
    Write-Error 'GENIUS_TOKEN is empty in env.json. Paste your Genius Client Access Token into env.json before building a release.'
    exit 1
}

Push-Location $root
try {
    # Windows PowerShell 5.1 prevrashaet stderr nativnoy komandy v zapisi
    # oshibok, i pri EAP=Stop lyuboe informacionnoe soobshchenie fluttera
    # (napr. "Nuget.exe not found") obryvaet skript. Na vremya zapuska
    # oslablyaem EAP i orientiruyemsya na $LASTEXITCODE (kak v install_release.ps1).
    $ErrorActionPreference = 'Continue'
    flutter build windows --release --dart-define-from-file=env.json @args 2>&1 |
        ForEach-Object { Write-Host $_ }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($buildExit -ne 0) {
        Write-Error "flutter build windows failed with exit code $buildExit"
        exit $buildExit
    }

    $exe = Join-Path $root 'build\windows\x64\runner\Release\player.exe'
    if (-not (Test-Path $exe)) {
        # Diagnostika: esli cherez args popal drugoy rezhim/ploshchadka,
        # pokazhem chto voobshche sobralos, a potom ostanovimsya s oshibkoy.
        $buildRoot = Join-Path $root 'build\windows\x64\runner'
        if (Test-Path $buildRoot) {
            $candidates = Get-ChildItem -Path $buildRoot -Filter 'player.exe' -Recurse -ErrorAction SilentlyContinue
            if ($candidates) {
                Write-Warning "Release\player.exe not found, but the following executables were built:"
                $candidates | ForEach-Object { Write-Warning "  $($_.FullName)" }
            } else {
                Write-Warning "No player.exe found under $buildRoot"
            }
        }
        Write-Error "Expected executable not found: $exe"
        exit 1
    }

    $exeDir = Split-Path $exe -Parent

    # Soulseek bridge (.NET, self-contained): published and installed into
    # soulseek\ by the CMake build (windows/CMakeLists.txt). Without it the
    # app runs, but Soulseek is unavailable - do not ship such a build.
    $bridgeDir = Join-Path $exeDir 'soulseek'
    $bridgeFiles = @('soulseek-desktop.dll', 'soulseek-desktop.runtimeconfig.json',
        'hostfxr.dll', 'coreclr.dll', 'Soulseek.dll',
        'LICENSE.Soulseek.NET.txt', 'NOTICE.Soulseek.NET.txt', 'THIRD_PARTY_NOTICES.md')
    foreach ($f in $bridgeFiles) {
        if (-not (Test-Path (Join-Path $bridgeDir $f))) {
            Write-Error "Soulseek bridge file missing: soulseek\$f. Install the .NET 9 SDK (dotnet on PATH) and rebuild."
            exit 1
        }
    }
    $bridgeSize = (Get-ChildItem $bridgeDir -Recurse -File | Measure-Object -Property Length -Sum).Sum

    Write-Host ''
    Write-Host 'Build succeeded.' -ForegroundColor Green
    $exeSize = (Get-Item $exe).Length
    Write-Host ('EXE: {0} ({1:N1} MB)' -f $exe, ($exeSize / 1MB))
    Write-Host ('Soulseek bridge: {0} ({1:N1} MB)' -f $bridgeDir, ($bridgeSize / 1MB))
    Write-Host "Release folder: $exeDir"
    Write-Host 'Note: build is unsigned. To sign it use: signtool.exe sign /a /fd SHA256 <exe>'

    if ($Zip) {
        $zipPath = Join-Path $root 'build\player-windows-x64.zip'
        Write-Host ''
        Write-Host "Zipping release folder to $zipPath ..."
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Compress-Archive -Path (Join-Path $exeDir '*') -DestinationPath $zipPath -Force
        } finally {
            $ProgressPreference = $oldProgress
        }
        Write-Host ('Zip: {0} ({1:N1} MB)' -f $zipPath, ((Get-Item $zipPath).Length / 1MB))
        # The in-app updater (lib/core/update_service.dart) looks for this exact asset name.
        Write-Host 'Attach it to the GitHub release as player-windows-x64.zip (next to app-release.apk).'
    }
} finally {
    Pop-Location
}
