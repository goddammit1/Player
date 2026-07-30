# Release-sborka APK c GENIUS_TOKEN u3 env.json (--dart-define-from-file).
# Vse dopolnitelnye argumenty probrasyvayutsya v flutter build.
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

# The release keystore is referenced from android/key.properties as
# storeFile=app/player-release.jks, which Gradle resolves relative to the
# android/ project directory. We keep a sanity-check path here so the
# build fails early with a clear message if it disappears.
$keystore = Join-Path $root 'android\app\player-release.jks'
$keyprops = Join-Path $root 'android\key.properties'
if (-not (Test-Path $keystore)) {
    Write-Error "Release keystore not found: $keystore. Restore it from backup before building a release."
    exit 1
}
if (-not (Test-Path $keyprops)) {
    Write-Error "Signing config not found: $keyprops. It must point to the release keystore."
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

Push-Location $root
try {
    flutter build apk --release --dart-define-from-file=env.json @args
    if ($LASTEXITCODE -ne 0) {
        Write-Error "flutter build apk failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }

    $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path $apk)) {
        # Flutter sometimes outputs split APKs if ABI filtering is configured.
        $candidates = Get-ChildItem -Path (Join-Path $root 'build\app\outputs\flutter-apk') -Filter '*-release.apk' -ErrorAction SilentlyContinue
        if ($candidates) {
            Write-Warning "app-release.apk not found, but the following release APKs were built:"
            $candidates | ForEach-Object { Write-Warning "  $($_.Name)" }
        }
        Write-Error "Expected APK not found: $apk"
        exit 1
    }

    Write-Host ''
    Write-Host 'Build succeeded.' -ForegroundColor Green
    Write-Host "APK: $apk"

    if ($apksigner) {
        Write-Host ''
        Write-Host 'APK signing certificate (SHA-256):' -ForegroundColor Cyan
        # apksigner needs JAVA_HOME. Try Android Studio bundled JBR first.
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

    Write-Host ''
    Write-Host 'Install on device: tools\install_release.ps1'
} finally {
    Pop-Location
}
