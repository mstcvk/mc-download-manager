<p align="center">
  <img src="docs/icon.png" width="128" alt="MC Download Manager icon">
</p>

<h1 align="center">MC Download Manager</h1>

<p align="center">
  A fast, open-source download manager for macOS.<br>
  Captures Safari, Chrome and Firefox downloads, accelerates them with up to 16 parallel connections and downloads videos from web pages.
</p>

<p align="center">
  <a href="README.tr.md">🇹🇷 Türkçe</a> · <a href="https://github.com/mstcvk/mc-download-manager/releases">Releases</a> · <a href="#installation">Homebrew</a> · <a href="#building-from-source">Build</a>
</p>

<p align="center">
  <a href="https://youtu.be/SsHWR9UFCM0"><img src="docs/video-en.png" width="720" alt="Watch the 1-minute MC Download Manager video on YouTube"></a><br>
  <sub>▶ <a href="https://youtu.be/SsHWR9UFCM0">Watch the 1-minute overview</a> · <a href="https://youtu.be/Set5DFC5xmg">Türkçe video</a></sub>
</p>

---

Everything ships in a single `.app`: the Safari extension, the Chrome and Firefox extensions, `yt-dlp` and `ffmpeg` are bundled.
Open the DMG, drag the app to *Applications*, done. The interface is in **English** and **Turkish** (follows the system language).

## Features

- **Multi-connection downloads** — files are split into HTTP `Range` requests (8 connections by default, 1–16 configurable).
  Falls back to a single stream when the server does not support ranges; adapts the connection count on `429`/`503` throttling.
- **Pause / resume** — segment state is persisted on disk, so downloads continue where they left off even after a restart.
- **Browser integration** — one shared WebExtension for Safari, Google Chrome, Brave, Opera and Firefox. A step-by-step setup wizard handles each browser
  one at a time (extension files are placed in `~/Downloads/MC Download Manager/Browser Plugins/`).
  The browser download is cancelled and handed to the app together with cookies, `Referer` and `User-Agent`; captured file types are configurable.
  If the app is not running, the extension starts it (native messaging) and hands the download over once it is up; if it cannot, the browser keeps the download.
- **Video downloads** — `<video>`, `.m3u8` and `.mpd` streams on the page are detected; "Download video from this page" uses the bundled
  yt-dlp (with ffmpeg merging). Default output is MP4 up to 1080p (container and resolution configurable). Browser cookies are passed to
  yt-dlp, and an in-app sign-in window handles age-restricted videos. yt-dlp can be updated from GitHub with one click.
- **MP3 downloads** — "Download MP3 from this page" uses the same bundled yt-dlp to save only the audio as MP3 (best quality,
  converted with ffmpeg), regardless of the video quality setting. Cookies and the sign-in window work the same way; finished files go to *Music*.
- **Clipboard** — copy a link and the app asks whether to download it; paste a link into the main window with ⌘V.
- **UI** — sidebar categories (Images, Music, Video, Apps, Documents, Archives…), sortable table, search,
  an IDM-style per-download window (connection table, segment bar, auto-close option), menu-bar item, notifications.
- **Lives in the menu bar** — opens at login (enabled after the first-run setup), starts without a window and without a Dock icon; the browser bridge stays up so extensions never need you to open the app. Closing the window keeps it running; quit from the menu bar icon.

<p align="center">
  <img src="docs/main.png" width="720" alt="Main window"><br>
  <img src="docs/detail.png" width="520" alt="Download window">
</p>

## Installation

**Homebrew**

```bash
brew install --cask mstcvk/tap/mc-download-manager
```

Update with `brew upgrade --cask mc-download-manager`. Then continue with the browser steps (2 and 3) below.

**Manual**

1. Download the DMG from [Releases](https://github.com/mstcvk/mc-download-manager/releases), open it and drag **MC Download Manager.app** to *Applications*.
   - Builds that are not notarized trigger a Gatekeeper warning on first launch: *System Settings ▸ Privacy & Security ▸ "Open Anyway"*.
2. **Safari:** *Safari ▸ Settings ▸ Extensions ▸ MC Download Manager* → enable and allow for all websites.
   - For ad-hoc signed builds Safari also requires *Develop ▸ Allow Unsigned Extensions* (not needed for Developer ID signed builds).
3. **Chrome:** open `chrome://extensions`, turn on *Developer mode*, choose *Load unpacked* and select the folder shown in the app under
   *Settings ▸ Browser ▸ Show Folder* (`ChromeExtension` inside the app bundle).
4. **Firefox:** *Settings ▸ Browser Extensions ▸ Open Setup Wizard… ▸ Add to Firefox*. The add-on is signed by Mozilla and bundled
   with the app; Firefox asks for confirmation once and keeps it installed (Firefox 140 or later).

The app runs a tiny HTTP bridge on `127.0.0.1:48213` that only accepts requests from browser extensions (`Origin` check).

## Building from source

Requirements: macOS 13+, Xcode 15+, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/fetch-tools.sh   # downloads universal yt-dlp and ffmpeg (arm64 + x86_64) into Tools/
scripts/build.sh         # Release build, code signing and build/MC Download Manager <version>.dmg
```

For development run `xcodegen generate` and open `MCDownloadManager.xcodeproj`.

Developer ID signing and notarization:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary scripts/build.sh
```

The GitHub Actions workflow (`.github/workflows/build.yml`) builds a DMG on every push and attaches it to the release on `v*` tags.

### Updating the Homebrew cask

After a release's DMG is uploaded, `scripts/update-cask.sh` bumps `Casks/mc-download-manager.rb` in
[mstcvk/homebrew-tap](https://github.com/mstcvk/homebrew-tap) to the version in `project.yml` (checksum taken from the release asset).

### Publishing the Chrome extension to the Web Store

Chrome only installs extensions silently from the Chrome Web Store, so until the extension is published the app guides users through
*Developer mode ▸ Load unpacked*. To publish:

```bash
scripts/pack-extension.sh      # → build/mc-download-manager-chrome-<version>.zip
```

Upload the zip in the [Chrome Web Store developer console](https://chrome.google.com/webstore/devconsole), then set
`BrowserIntegration.chromeWebStoreURL` to the store page; "Install" will open it directly.

### Signing the Firefox add-on

Release Firefox only installs add-ons signed by Mozilla. `scripts/build.sh` runs `scripts/pack-firefox.sh`, which builds the
Firefox variant of the manifest (`background.scripts`, `browser_specific_settings.gecko`) and, when
[AMO API credentials](https://addons.mozilla.org/developers/addon/api/key/) are available, signs it as an unlisted add-on
(once per version) and bundles it as `FirefoxExtension.xpi`. Store the credentials in the login keychain:

```bash
security add-generic-password -s mc-download-manager-amo -a issuer -w 'user:…'
security add-generic-password -s mc-download-manager-amo -a secret -w '…'
```

Without credentials the unsigned add-on is bundled; Firefox can then only load it temporarily via `about:debugging`.

## Project layout

```
App/Sources/DownloadManager/
  Engine/SegmentedDownloader.swift   multi-connection HTTP downloader (URLSession, Range, adaptive concurrency)
  Engine/VideoDownloader.swift       yt-dlp wrapper (progress parsing, cookie file)
  Engine/DownloadStore.swift         queue, persistence, speed measurement
  Engine/ClipboardWatcher.swift      clipboard monitoring and ⌘V handling
  Server/LocalServer.swift           minimal HTTP server on Network.framework
  Server/ServerController.swift      /ping /download /downloads /action endpoints
  Views/                             SwiftUI (main window, download window, settings)
App/Resources/Localizable.xcstrings  English (base) + Turkish strings
SafariExtension/                     Safari Web Extension target (native messaging launches the app)
NativeHost/                          native messaging host for Chrome/Brave/Opera/Edge/Firefox (launches the app; registered by NativeHostRegistry)
Extension/                           shared WebExtension (manifest v3, background, content, popup, _locales)
scripts/                             fetch-tools.sh, build.sh, pack-extension.sh, update-cask.sh, make_icons.swift
project.yml                          xcodegen project spec
```

### Bridge API

| Endpoint | Description |
|---|---|
| `GET /ping` | version, yt-dlp availability, active download count |
| `POST /download` | `{url, filename?, referer?, userAgent?, cookieHeader?, cookies?[], kind: "file"\|"video"\|"audio", segments?}` |
| `GET /downloads` | status of the last 50 downloads |
| `POST /action` | `{id, action: "pause"\|"resume"\|"cancel"\|"remove"}` |

The bridge only answers requests whose `Origin` is a browser-extension origin (`chrome-extension://`, `safari-web-extension://`, `moz-extension://`) and whose `Host` is the loopback address; requests from ordinary web pages (including `Origin: null`) are rejected, and CORS headers are only sent to extension origins.

## Contributing

Issues and pull requests are welcome. Translations live in `App/Resources/Localizable.xcstrings` and `Extension/_locales/`.

## License

The code is licensed under the MIT License (see `LICENSE`). Bundled binaries keep their own licenses:
[yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) and [FFmpeg](https://ffmpeg.org) (static build from martin-riedl.de, GPL).
If you distribute builds with the GPL ffmpeg binary, keep the source-availability obligation in mind, or point `scripts/fetch-tools.sh` to an LGPL build.
