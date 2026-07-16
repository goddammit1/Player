$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cfg = Get-Content (Join-Path $root 'env.json') -Raw | ConvertFrom-Json
$t = [string]$cfg.GENIUS_TOKEN
if ([string]::IsNullOrWhiteSpace($t)) {
    Write-Output 'GENIUS_TOKEN: EMPTY'
} else {
    Write-Output ('GENIUS_TOKEN: present, len=' + $t.Length)
}

$headers = @{ Authorization = ('Bearer ' + $t) }
try {
    $r = Invoke-WebRequest -Uri 'https://api.genius.com/search?q=imagine+dragons+believer' -Headers $headers -UseBasicParsing
    Write-Output ('genius_http=' + [int]$r.StatusCode)
    $j = $r.Content | ConvertFrom-Json
    $first = $j.response.hits[0].result
    Write-Output ('genius_first_title=' + $first.full_title)
    Write-Output ('genius_song_art_image_url=' + $first.song_art_image_url)
    Write-Output ('genius_header_image_url=' + $first.header_image_url)
} catch {
    if ($_.Exception.Response) {
        Write-Output ('genius_http=' + [int]$_.Exception.Response.StatusCode)
    }
    Write-Output ('genius_error=' + $_.Exception.Message)
}

try {
    $ri = Invoke-WebRequest -Uri 'https://itunes.apple.com/search?term=imagine+dragons+believer&entity=song&limit=1' -UseBasicParsing
    Write-Output ('itunes_http=' + [int]$ri.StatusCode)
    $ji = $ri.Content | ConvertFrom-Json
    Write-Output ('itunes_artworkUrl100=' + $ji.results[0].artworkUrl100)
} catch {
    Write-Output ('itunes_error=' + $_.Exception.Message)
}
