#!/bin/zsh
# Release build + (optional) Developer ID signing/notarization + DMG.
#
#   scripts/build.sh                 → build/MC Download Manager <version>.dmg (ad-hoc signed)
#   CODESIGN_IDENTITY="Developer ID Application: Ad Soyad (TEAMID)" scripts/build.sh
#   ... + NOTARY_PROFILE=<notarytool keychain profili>  → notarize + staple
#   ... or NOTARY_KEY=<AuthKey_….p8> NOTARY_KEY_ID=<key id> NOTARY_ISSUER=<issuer id>  (App Store Connect API key, no keychain)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MC Download Manager"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
EXPORT="$BUILD/release"
# Signing identity: explicit CODESIGN_IDENTITY, else the best certificate in the keychain
# (Developer ID Application → Apple Development → ad-hoc "-"). Apple Development is enough for this Mac
# (Safari loads the extension without "Allow Unsigned Extensions"); distribution to others needs Developer ID.
pick_identity() {
  local ids; ids="$(security find-identity -v -p codesigning 2>/dev/null)"
  local id
  id="$(printf '%s\n' "$ids" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  [[ -n "$id" ]] && { echo "$id"; return; }
  id="$(printf '%s\n' "$ids" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  [[ -n "$id" ]] && { echo "$id"; return; }
  printf '%s\n' "-"   # zsh's echo swallows a lone "-" (it ends the option list)
}
IDENTITY="${CODESIGN_IDENTITY:-$(pick_identity)}"
# Notarization profile (xcrun notarytool store-credentials). Defaults to the local profile when it exists.
if [[ -z "${NOTARY_PROFILE:-}" && -z "${NOTARY_KEY:-}" && "$IDENTITY" != "-" ]] && xcrun notarytool history --keychain-profile "mc-download-manager" >/dev/null 2>&1; then
  NOTARY_PROFILE="mc-download-manager"
fi
# notarytool credentials: an API key file passed directly, else the keychain profile.
NOTARY_AUTH=()
if [[ -n "${NOTARY_KEY:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required with NOTARY_KEY}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER required with NOTARY_KEY}")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"

echo "▶ Tools (yt-dlp, ffmpeg)"
[[ -x Tools/yt-dlp && -x Tools/ffmpeg ]] || scripts/fetch-tools.sh

echo "▶ Icons"
mkdir -p "$BUILD"
swiftc -O scripts/make_icons.swift -o "$BUILD/make_icons"
"$BUILD/make_icons" "$BUILD/icons" >/dev/null
cp "$BUILD"/icons/ext/*.png Extension/icons/
mkdir -p App/Assets.xcassets/AppIcon.appiconset
cp "$BUILD"/icons/AppIcon.iconset/*.png App/Assets.xcassets/AppIcon.appiconset/
for n in MenuBarIcon MenuBarIconActive; do cp "$BUILD/icons/menubar/$n.png" "$BUILD/icons/menubar/$n@2x.png" "App/Assets.xcassets/$n.imageset/"; done

if command -v xcodegen >/dev/null; then
  echo "▶ Xcode project (xcodegen)"
  xcodegen generate >/dev/null
fi

echo "▶ xcodebuild (Release)"
rm -rf "$EXPORT"
xcodebuild -project MCDownloadManager.xcodeproj -scheme MCDownloadManager -configuration Release \
  -derivedDataPath "$DERIVED" \
  CONFIGURATION_BUILD_DIR="$EXPORT" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  build 2>&1 | grep -E "error:|warning: Tools|BUILD" || true

APP="$EXPORT/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "✗ App was not produced"; exit 1; }

echo "▶ Firefox add-on"
scripts/pack-firefox.sh
EXT_VERSION="$(python3 -c "import json;print(json.load(open('Extension/manifest.json'))['version'])")"
FF_SIGNED="$BUILD/mc-download-manager-firefox-$EXT_VERSION-signed.xpi"
if [[ -f "$FF_SIGNED" ]]; then
  cp "$FF_SIGNED" "$APP/Contents/Resources/FirefoxExtension.xpi"
else
  echo "  ⚠︎ bundling the unsigned add-on (Firefox loads it only temporarily)"
  cp "$BUILD/mc-download-manager-firefox-$EXT_VERSION.xpi" "$APP/Contents/Resources/FirefoxExtension-unsigned.xpi"
fi

echo "▶ Code signing ($IDENTITY)"
# Notarization requires a secure timestamp; ad-hoc signatures cannot have one.
if [[ "$IDENTITY" == "-" ]]; then TS="--timestamp=none"; else TS="--timestamp"; fi
HELPER_ENT="$BUILD/helpers.entitlements"
cat > "$HELPER_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
PLIST
# Inside-out: helper binaries → extension → app
for bin in "$APP/Contents/Helpers/"*; do
  [[ -f "$bin" ]] && codesign --force --options runtime $TS --entitlements "$HELPER_ENT" --sign "$IDENTITY" "$bin"
done
codesign --force --options runtime $TS \
  --entitlements SafariExtension/SafariExtension.entitlements \
  --sign "$IDENTITY" "$APP/Contents/PlugIns/$APP_NAME Extension.appex"
codesign --force --options runtime $TS \
  --entitlements App/App.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature verified"

if (( ${#NOTARY_AUTH} )) && [[ "$IDENTITY" != "-" ]]; then
  echo "▶ Notarization — app"
  ZIP="$BUILD/$APP_NAME.zip"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

echo "▶ DMG"
DMG="$BUILD/$APP_NAME $VERSION.dmg"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
MC Download Manager $VERSION

1) Drag "MC Download Manager.app" to the Applications folder.
2) If macOS blocks the first launch: System Settings ▸ Privacy & Security ▸ "Open Anyway".
3) Safari: Settings ▸ Extensions ▸ enable MC Download Manager.
   Chrome: chrome://extensions ▸ Developer mode ▸ "Load unpacked" ▸ pick the folder shown in
           the app under Settings ▸ Browser ▸ "Show Folder".
   Firefox: Settings ▸ Browser Extensions ▸ "Open Setup Wizard…" ▸ "Add to Firefox".

--- Türkçe ---
1) "MC Download Manager.app" simgesini Applications klasörüne sürükleyin.
2) İlk açılışta macOS uyarı verirse: Sistem Ayarları ▸ Gizlilik ve Güvenlik ▸ "Yine de Aç".
3) Safari: Ayarlar ▸ Uzantılar ▸ MC Download Manager'ı etkinleştirin.
   Chrome: chrome://extensions ▸ Geliştirici modu ▸ "Paketlenmemiş öğe yükle" ▸
           uygulama içindeki Ayarlar ▸ Tarayıcı ▸ "Klasörü Göster" ile açılan klasörü seçin.
   Firefox: Ayarlar ▸ Tarayıcı Eklentileri ▸ "Kurulum Sihirbazını Aç…" ▸ "Firefox'a Ekle".
TXT
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if (( ${#NOTARY_AUTH} )) && [[ "$IDENTITY" != "-" ]]; then
  echo "▶ Notarization — DMG"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | sed -n '1p'
fi

echo "✓ Ready: $DMG"
du -h "$DMG" | cut -f1
