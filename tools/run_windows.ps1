# flutter run dlya Windows-desktopa c GENIUS_TOKEN iz env.json (--dart-define-from-file).
# Analogichno tools/run.ps1 dlya Android, no target = -d windows.
# Vse dopolnitelnye argumenty probrasyvayutsya v flutter run.
# NOTE: derzhat etot fayl ASCII-only. Windows PowerShell 5.1 chitaet .ps1 kak
# ANSI, poetomu ne-ASCII simvoly bez BOM lomayut parsering (kak v install_release.ps1).
$ErrorActionPreference = 'Stop'

# Koren repo: roditelskaya papka ot tools/ (sama papka skripta).
$root = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $root 'env.json'

# Proverka nalichiya env.json i tokena Genius.
if (-not (Test-Path $envFile)) {
    Write-Error "env.json not found: $envFile. Copy env.json.example -> env.json and paste your Genius Client Access Token."
    exit 1
}

$config = Get-Content $envFile -Raw | ConvertFrom-Json
$token = [string]$config.GENIUS_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or $token -eq 'PASTE_GENIUS_TOKEN_HERE') {
    Write-Warning 'GENIUS_TOKEN is empty in env.json - Genius will be skipped, iTunes fallback only.'
}

# Zapusk iz kornya repo.
Push-Location $root
try {
    # Windows-desktop: target -d windows, dart-defines iz env.json,
    # vse dop. args ($args) probrasyvayutsya vnytr (napr. --dart-define=X=y).
    flutter run -d windows --dart-define-from-file=env.json @args
} finally {
    Pop-Location
}