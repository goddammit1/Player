# Устанавливает release APK на подключённое устройство через adb.
$ErrorActionPreference = 'Stop'
$apk = Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) {
    Write-Error "APK not found: $apk"
    exit 1
}

# Ищем adb: сначала в PATH, потом в стандартном расположении Android SDK.
$adb = 'adb'
$cmd = Get-Command adb -ErrorAction SilentlyContinue
if (-not $cmd) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $candidate) {
        $adb = $candidate
    } else {
        Write-Error 'adb not found in PATH or default Android SDK location.'
        exit 1
    }
}

Write-Host "Using adb: $adb"
& $adb devices
Write-Host "Installing $apk ..."
& $adb install -r $apk
