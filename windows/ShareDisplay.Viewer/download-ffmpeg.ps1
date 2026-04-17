# Downloads a Windows x64 *shared* FFmpeg build (DLLs in bin\) into ffmpeg\bin next to this script.
# Run once from PowerShell:  .\download-ffmpeg.ps1
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$dest = Join-Path $here "ffmpeg\bin"
$tmpRoot = Join-Path $env:TEMP ("ffmpeg-dl-" + [Guid]::NewGuid().ToString("N"))
$zip = Join-Path $tmpRoot "ffmpeg.zip"

# BtbN nightly: win64 gpl *shared* — includes avcodec-*.dll next to ffmpeg.exe
$url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"

Write-Host "Downloading FFmpeg (shared)…"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Write-Host "Extracting…"
    Expand-Archive -Path $zip -DestinationPath $tmpRoot -Force
    $bin = Get-ChildItem -Path $tmpRoot -Filter "bin" -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { (Get-ChildItem -LiteralPath $_.FullName -Filter "avcodec-*.dll" -File -ErrorAction SilentlyContinue).Count -gt 0 } |
        Select-Object -First 1
    if (-not $bin) {
        throw "Could not find a bin folder containing avcodec-*.dll inside the archive."
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $bin.FullName "*") -Destination $dest -Force
    Write-Host "OK: FFmpeg DLLs copied to:`n  $dest"
    $n = (Get-ChildItem $dest "avcodec-*.dll").Count
    if ($n -lt 1) { throw "Copy failed: no avcodec-*.dll in destination." }
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
