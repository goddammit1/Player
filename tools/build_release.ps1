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

Push-Location $root
try {
    flutter build apk --release --dart-define-from-file=env.json @args
    Write-Host ''
    Write-Host 'Done. Install on device: tools\install_release.ps1'
} finally {
    Pop-Location
}
