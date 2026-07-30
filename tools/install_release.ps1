# Installs the release APK onto a connected device via adb.
# Auto-fixes signature conflicts (INSTALL_FAILED_UPDATE_INCOMPATIBLE):
# in that case it uninstalls the old build and installs fresh.
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI,
# so non-ASCII text without a BOM corrupts string literals and breaks parsing.
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) {
    # If a fat APK was not built, show any available release APKs for diagnosis.
    $apkDir = Join-Path $root 'build\app\outputs\flutter-apk'
    if (Test-Path $apkDir) {
        $candidates = Get-ChildItem -Path $apkDir -Filter '*-release.apk' -ErrorAction SilentlyContinue
        if ($candidates) {
            Write-Warning "app-release.apk not found. The following release APKs exist:"
            $candidates | ForEach-Object { Write-Warning "  $($_.Name)" }
        }
    }
    Write-Error "APK not found: $apk. Build it first: .\tools\build_release.ps1"
    exit 1
}

# Locate adb. Prefer the real SDK adb.exe over any PATH shim, because a broken
# C:\Windows\system32\adb.cmd can shadow it and fail with "cannot find path".
$adb = $null
$sdkAdb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (Test-Path $sdkAdb) {
    $adb = $sdkAdb
} else {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $adb = $cmd.Source }
}
if (-not $adb) {
    Write-Error 'adb not found (checked SDK platform-tools and PATH).'
    exit 1
}

# Locate apksigner for v2/v3 signature verification. Prefer the newest
# build-tools version, fall back to PATH.
$apksigner = $null
$buildToolsRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools'
if (Test-Path $buildToolsRoot) {
    $apksigner = Get-ChildItem -Path $buildToolsRoot -Filter apksigner.bat -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1 |
        ForEach-Object { $_.FullName }
}
if (-not $apksigner) {
    $cmd = Get-Command apksigner -ErrorAction SilentlyContinue
    if ($cmd) { $apksigner = $cmd.Source }
}

# applicationId (needed to reinstall on signature conflict).
$appId = 'com.player.player'

Write-Host "Using adb: $adb"

# Make sure a device is actually connected and authorized.
$devicesRaw = & $adb devices
$devicesRaw | Write-Host
$connected = @($devicesRaw | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' })
$unauthorized = @($devicesRaw | Where-Object { $_ -match '\tunauthorized$' })
$offline = @($devicesRaw | Where-Object { $_ -match '\toffline$' })

if ($unauthorized.Count -gt 0) {
    Write-Error 'Device connected but unauthorized. Unlock the phone and confirm the USB debugging (RSA) prompt, then rerun.'
    exit 1
}
if ($offline.Count -gt 0) {
    Write-Error 'Device is offline. Reconnect the cable or run: adb kill-server; adb start-server, then retry.'
    exit 1
}
if ($connected.Count -eq 0) {
    Write-Error 'No connected devices. Enable USB debugging, use a data cable, and check adb devices.'
    exit 1
}

# Print APK certificate fingerprint for diagnosis.
if ($apksigner) {
    Write-Host ''
    Write-Host 'APK signing certificate (SHA-256):' -ForegroundColor Cyan
    $javaHomeCandidates = @(
        "$env:LOCALAPPDATA\Android\Android Studio\jbr"
        "C:\Program Files\Android\Android Studio\jbr"
        "C:\Program Files\Java\jdk-17.0.3"
    )
    foreach ($jh in $javaHomeCandidates) {
        if (Test-Path $jh) { $env:JAVA_HOME = $jh; break }
    }
    & $apksigner verify --print-certs $apk 2>&1 |
        Select-String -Pattern 'SHA-256 digest' |
        ForEach-Object { Write-Host "  $_" }
}

# Print installed app certificate fingerprint, if the app is already installed.
$installedFingerprint = $null
$pmList = & $adb shell pm list packages $appId 2>&1
if (($pmList | Out-String) -match "package:$appId") {
    Write-Host ''
    Write-Host 'Installed app signing certificate (SHA-256):' -ForegroundColor Cyan
    $dump = & $adb shell pm dump $appId 2>&1 | Out-String
    # Android 7+ prints fingerprints as "signatures=[PackageSignatures{...}]" with hex hashes.
    $fingerprints = $dump -split "`r?`n" | Select-String -Pattern '\b([0-9A-Fa-f]{2}:){15,31}[0-9A-Fa-f]{2}\b'
    if ($fingerprints) {
        $fingerprints | ForEach-Object { Write-Host "  $_" }
        $installedFingerprint = ($fingerprints | Select-Object -First 1).ToString()
    } else {
        Write-Host '  (could not extract fingerprint from pm dump)'
    }
}

# adb writes install failures to stderr; with ErrorActionPreference=Stop the
# merged 2>&1 stream is turned into a terminating error and the script dies
# before we can inspect it. Relax it here so we can detect the signature
# conflict and auto-reinstall.
$ErrorActionPreference = 'Continue'
Write-Host ""
Write-Host "Installing $apk ..."
$output = & $adb install -r $apk 2>&1
$output | Write-Host
$joined = ($output | Out-String)

if ($joined -match 'Success') {
    Write-Host 'Installed successfully.' -ForegroundColor Green
    exit 0
}

# Signature conflict: the installed build is signed with a different key
# (debug or an older release). Reinstall from scratch.
if ($joined -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' -or
    $joined -match 'signatures do not match' -or
    $joined -match 'INSTALL_FAILED_VERSION_DOWNGRADE') {
    Write-Warning ""
    Write-Warning "Signature/version conflict with installed $appId."
    if ($apksigner -and $installedFingerprint) {
        Write-Warning 'The APK and the installed app have different signing certificates.'
        Write-Warning 'This usually means the old build was signed with a different keystore.'
    }
    Write-Warning "Uninstalling old build and reinstalling (app data will be reset)."
    & $adb uninstall $appId 2>&1 | Write-Host
    $retry = & $adb install $apk 2>&1
    $retry | Write-Host
    if (($retry | Out-String) -match 'Success') {
        Write-Host 'Installed successfully after reinstall.' -ForegroundColor Green
        exit 0
    }
    Write-Error 'Reinstall failed. See adb output above.'
    exit 1
}

Write-Error 'Install failed. See adb output above.'
exit 1
