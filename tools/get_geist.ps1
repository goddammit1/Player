# Скачивает статические TTF шрифта Geist Sans в assets/fonts.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot '..\assets\fonts'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$base = 'https://github.com/vercel/geist-font/raw/main/packages/next/dist/fonts/geist-sans/'
$files = @('Geist-Regular.ttf', 'Geist-Medium.ttf', 'Geist-SemiBold.ttf', 'Geist-Bold.ttf')
foreach ($f in $files) {
    $out = Join-Path $dir $f
    Write-Host "Downloading $f ..."
    Invoke-WebRequest -Uri ($base + $f) -OutFile $out
}
Get-ChildItem $dir | Select-Object Name, Length
