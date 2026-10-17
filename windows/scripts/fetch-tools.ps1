# Downloads the yt-dlp and ffmpeg binaries that ship next to the app (into Tools\).
# Sources:
#   yt-dlp : https://github.com/yt-dlp/yt-dlp/releases          (yt-dlp.exe)
#   ffmpeg : https://github.com/yt-dlp/FFmpeg-Builds/releases   (win64 gpl, the build yt-dlp recommends)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$Tools = Join-Path $Root 'Tools'
New-Item -ItemType Directory -Force $Tools | Out-Null

$YtDlpUrl = if ($env:YTDLP_URL) { $env:YTDLP_URL } else { 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' }
$FfmpegUrl = if ($env:FFMPEG_URL) { $env:FFMPEG_URL } else { 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' }

$ytdlp = Join-Path $Tools 'yt-dlp.exe'
if (-not (Test-Path $ytdlp)) {
    Write-Host '-> downloading yt-dlp...'
    Invoke-WebRequest $YtDlpUrl -OutFile $ytdlp
}

$ffmpeg = Join-Path $Tools 'ffmpeg.exe'
if (-not (Test-Path $ffmpeg)) {
    Write-Host '-> downloading ffmpeg...'
    $zip = Join-Path $Tools 'ffmpeg.zip'
    $unpack = Join-Path $Tools '_ffmpeg'
    Invoke-WebRequest $FfmpegUrl -OutFile $zip
    if (Test-Path $unpack) { Remove-Item -Recurse -Force $unpack }
    Expand-Archive $zip -DestinationPath $unpack
    Copy-Item (Get-ChildItem $unpack -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName $ffmpeg
    Remove-Item -Recurse -Force $unpack, $zip
}

Write-Host 'Tools ready:'
& $ytdlp --version
& $ffmpeg -version | Select-Object -First 1
