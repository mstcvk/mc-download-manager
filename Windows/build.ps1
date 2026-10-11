# Builds the Windows app into Windows\dist\MC Download Manager\ (exe + browser extension) and a zip next to it.
#
#   .\Windows\build.ps1                  # framework-dependent: small, needs the .NET 10 Desktop Runtime
#   .\Windows\build.ps1 -SelfContained   # bundles the runtime: larger, runs on any Windows 10/11 x64
param([switch]$SelfContained)
$ErrorActionPreference = 'Stop'

$project = Join-Path $PSScriptRoot 'MCDownloadManager\MCDownloadManager.csproj'
$dist = Join-Path $PSScriptRoot 'dist'
$out = Join-Path $dist 'MC Download Manager'

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$sc = if ($SelfContained) { 'true' } else { 'false' }
dotnet publish $project -c Release -r win-x64 --self-contained $sc -p:PublishSingleFile=true -p:DebugType=none -o $out
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

$version = ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$suffix = if ($SelfContained) { '-standalone' } else { '' }
$zip = Join-Path $dist "MC-Download-Manager-$version-win-x64$suffix.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip
Write-Host "OK  $out"
Write-Host "OK  $zip"
