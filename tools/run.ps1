# flutter run c GENIUS_TOKEN u3 env.json (--dart-define-from-file).
# Vse dopolnitelnye argumenty probrasyvayutsya v flutter run.
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
    Write-Warning 'GENIUS_TOKEN is empty in env.json - Genius will be skipped, iTunes fallback only.'
}

Push-Location $root
try {
    flutter run --dart-define-from-file=env.json @args
} finally {
    Pop-Location
}
