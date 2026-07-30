# Backup the Android release keystore and key.properties.
# The keystore is the only way to sign update-compatible APKs.
# Losing it forces users to uninstall and reinstall the app.
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
# key.properties references storeFile=player-release.jks, which Gradle
# resolves relative to the android/app/ module directory.
$keystore = Join-Path $root 'android\app\player-release.jks'
$keyprops = Join-Path $root 'android\key.properties'

if (-not (Test-Path $keystore)) {
    Write-Error "Keystore not found: $keystore. Nothing to backup."
    exit 1
}
if (-not (Test-Path $keyprops)) {
    Write-Error "key.properties not found: $keyprops. Nothing to backup."
    exit 1
}

$defaultBackupDir = Join-Path $env:USERPROFILE 'Documents\Player-Keystore-Backup'
$backupDir = if ($args[0]) { $args[0] } else { $defaultBackupDir }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$destDir = Join-Path $backupDir $stamp

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Copy-Item -Path $keystore -Destination (Join-Path $destDir 'player-release.jks') -Force
Copy-Item -Path $keyprops -Destination (Join-Path $destDir 'key.properties') -Force

Write-Host "Keystore backed up to: $destDir" -ForegroundColor Green
Write-Host 'Store this backup in a safe place (cloud storage, password manager, etc.).'
Write-Host 'Without this keystore future updates cannot be installed over existing apps.'
