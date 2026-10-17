# Packs the WebExtension for Firefox: build\firefox\ (unpacked) + build\mc-download-manager-firefox-<version>.xpi
#
# Firefox shares the code in Extension\ with Chrome/Edge/Brave; only the manifest differs:
#   - background.scripts instead of background.service_worker (Firefox has no extension service workers)
#   - browser_specific_settings.gecko (add-on id, minimum version, data collection declaration)
#
# Release Firefox only installs add-ons signed by Mozilla. The add-on id and version are the same as in the macOS app,
# so its signed xpi (build/mc-download-manager-firefox-<version>-signed.xpi there) can be copied into build\ here.
# With AMO API credentials (AMO_JWT_ISSUER / AMO_JWT_SECRET) a new version is signed as an unlisted add-on
# (AMO rejects a version it has already signed). API keys: https://addons.mozilla.org/developers/addon/api/key/
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$GeckoId = 'mc-download-manager@mstcvk.github.io'
$Manifest = Get-Content (Join-Path $Root 'Extension\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Version = $Manifest.version
$Build = Join-Path $Root 'build'
$Stage = Join-Path $Build 'firefox'
$Xpi = Join-Path $Build "mc-download-manager-firefox-$Version.xpi"
$Signed = Join-Path $Build "mc-download-manager-firefox-$Version-signed.xpi"

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force $Stage | Out-Null
Copy-Item (Join-Path $Root 'Extension\*') $Stage -Recurse -Exclude 'manifest.json'

$Manifest.PSObject.Properties.Remove('background')
$Manifest | Add-Member background ([ordered]@{ scripts = @('background.js') })
$Manifest | Add-Member browser_specific_settings ([ordered]@{
    gecko = [ordered]@{
        id = $GeckoId
        strict_min_version = '140.0'
        # Everything stays on this PC: the extension only talks to the app on 127.0.0.1.
        data_collection_permissions = @{ required = @('none') }
    }
})
$json = $Manifest | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $Stage 'manifest.json'), $json, (New-Object Text.UTF8Encoding $false))

if (Test-Path $Xpi) { Remove-Item $Xpi }
# Zip entries must use forward slashes, which Compress-Archive on Windows PowerShell 5 does not guarantee.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($Xpi, 'Create')
try {
    Get-ChildItem $Stage -Recurse -File | ForEach-Object {
        $name = $_.FullName.Substring($Stage.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $name) | Out-Null
    }
} finally { $zip.Dispose() }
Write-Host "OK $Xpi"

if (Test-Path $Signed) {
    Write-Host "OK $Signed (already signed)"
} elseif ($env:AMO_JWT_ISSUER -and $env:AMO_JWT_SECRET) {
    Write-Host 'Signing with addons.mozilla.org (unlisted)'
    $out = Join-Path $Build 'firefox-signed'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    # Passed through the environment so the secret never shows up in the process list.
    $env:WEB_EXT_API_KEY = $env:AMO_JWT_ISSUER
    $env:WEB_EXT_API_SECRET = $env:AMO_JWT_SECRET
    npx --yes web-ext@8 sign --source-dir $Stage --artifacts-dir $out --channel unlisted
    Move-Item (Get-ChildItem $out -Filter *.xpi | Select-Object -First 1).FullName $Signed
    Remove-Item -Recurse -Force $out
    Write-Host "OK $Signed"
} else {
    Write-Host '  (not signed: no AMO credentials; release Firefox can only load it temporarily)'
}
