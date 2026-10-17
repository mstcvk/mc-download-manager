# Release build: self-contained app folder + portable zip, and a per-user installer when Inno Setup is installed.
#
#   scripts\build.ps1   ->  build\MC-Download-Manager-<version>-win-x64.zip
#                           build\MC-Download-Manager-<version>-setup.exe   (needs Inno Setup 6: winget install JRSoftware.InnoSetup)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$Build = Join-Path $Root 'build'
$Publish = Join-Path $Build 'publish'
$Version = ([xml](Get-Content 'src\MCDownloadManager.csproj')).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1

Write-Host '> Tools (yt-dlp, ffmpeg)'
if (-not ((Test-Path 'Tools\yt-dlp.exe') -and (Test-Path 'Tools\ffmpeg.exe'))) { & "$PSScriptRoot\fetch-tools.ps1" }

Write-Host '> Firefox add-on'
& "$PSScriptRoot\pack-firefox.ps1"
$ExtVersion = (Get-Content 'Extension\manifest.json' -Raw -Encoding UTF8 | ConvertFrom-Json).version

Write-Host "> dotnet publish ($Version)"
if (Test-Path $Publish) { Remove-Item -Recurse -Force $Publish }
dotnet publish src -c Release -r win-x64 --self-contained -p:PublishReadyToRun=true -o $Publish
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

$Signed = Join-Path $Build "mc-download-manager-firefox-$ExtVersion-signed.xpi"
if (Test-Path $Signed) {
    Copy-Item $Signed (Join-Path $Publish 'FirefoxExtension.xpi')
} else {
    Write-Host '  ! bundling the unsigned add-on (Firefox loads it only temporarily)'
    Copy-Item (Join-Path $Build "mc-download-manager-firefox-$ExtVersion.xpi") (Join-Path $Publish 'FirefoxExtension-unsigned.xpi')
}

Write-Host '> Zip'
$Zip = Join-Path $Build "MC-Download-Manager-$Version-win-x64.zip"
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive "$Publish\*" $Zip
Write-Host "OK $Zip"

$Iscc = @(
    (Get-Command iscc -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($Iscc) {
    Write-Host '> Installer'
    & $Iscc "/DAppVersion=$Version" "/DSourceDir=$Publish" "/O$Build" "$PSScriptRoot\installer.iss" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
    Write-Host "OK $(Join-Path $Build "MC-Download-Manager-$Version-setup.exe")"
} else {
    Write-Host '  (no installer: Inno Setup 6 not found)'
}
