# MC Download Manager for Windows

A Windows counterpart of the macOS app, so the browser extension in [`../Extension`](../Extension) works on Windows
too. The extension is used **unchanged**: this app speaks the same local bridge protocol (`127.0.0.1:48213`,
`/ping`, `/download`, `/downloads`, `/action`) and the same native messaging host name.

## Features

- Multi-connection downloads (HTTP `Range`, 1–16 connections, default 8), single-stream fallback, fewer
  connections on `429`/`503`, stalled connections are dropped and retried.
- Pause / resume, also after restarting the app (part state is saved to disk).
- Browser integration for Chrome, Edge and Brave (Firefox: see below). The extension cancels the browser's
  download and hands it to the app with cookies, `Referer` and `User-Agent`.
- If the app is not running, the extension starts it through native messaging and then hands over the download.
- Video download with yt-dlp (+ ffmpeg for merging, deno for YouTube). yt-dlp can be installed/updated from
  Settings; the download is checked against the release's `SHA2-256SUMS`.
- Category folders, tray icon, completion notifications, start with Windows, English/Turkish UI.
- Downloaded files get the Mark of the Web (`Zone.Identifier`), so SmartScreen and Office treat them as
  downloaded from the internet.

## Build

Needs the .NET 10 SDK.

```powershell
.\Windows\build.ps1                 # needs the .NET 10 Desktop Runtime on the target PC
.\Windows\build.ps1 -SelfContained  # bundles the runtime
```

Output: `Windows\dist\MC Download Manager\MCDownloadManager.exe` (+ the `Extension` folder) and a zip.

## Setup

1. Run `MCDownloadManager.exe`. It registers the native messaging host for the current user (HKCU) and starts
   listening on `127.0.0.1:48213`. Closing the window keeps it in the tray.
2. **🧩 Browser extension** → *Prepare extension folder* (copies the extension to
   `%LOCALAPPDATA%\MC Download Manager\Extension` and puts the path on the clipboard).
3. In the browser: `chrome://extensions` / `edge://extensions` → **Developer mode** → **Load unpacked** → paste the path.
4. The status bar shows *Extension connected* once the extension has talked to the app.

For video downloads, yt-dlp is found automatically if it is on `PATH` (e.g. `winget install yt-dlp.yt-dlp`),
or install it from **Settings → Video**. ffmpeg (`winget install yt-dlp.FFmpeg`) is needed to merge video and
audio; deno (`winget install DenoLand.Deno`) is recommended for YouTube.

**Firefox:** release Firefox only installs signed add-ons. The signed `.xpi` is produced by
`scripts/pack-firefox.sh` (macOS); for testing, load `Extension/manifest.json` through `about:debugging`
after adding the Firefox manifest changes from that script. The native host is registered for Firefox as well.

## Uninstall

```powershell
MCDownloadManager.exe --unregister   # removes the native host registry keys and the autostart entry
```

Then delete the folder, `%APPDATA%\MC Download Manager` (settings, list) and `%LOCALAPPDATA%\MC Download Manager`
(yt-dlp, unpacked extension).

## Data and security

- The bridge listens on loopback only and accepts requests only from extension origins
  (`chrome-extension://`, `moz-extension://`) or with the extension's custom header and no Origin; the `Host`
  header must be the loopback address. Web pages cannot drive it.
- Cookies are sent only to the host the download was requested for, never across a redirect to another host.
- Cookies for yt-dlp are written to `%APPDATA%\MC Download Manager\cookies\` and deleted with the download.
- File names from the server or the page are reduced to a single safe file name (no folders, no device names).
- Nothing is sent anywhere except the download itself and, when you ask for it, the yt-dlp release on GitHub.

Not ported from the macOS app: the in-app site login window, clipboard watching, the per-file detail window
(a details/log window is available from the context menu) and the update checker.
