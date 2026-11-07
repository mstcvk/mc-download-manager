import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            FileTypesSettings().tabItem { Label("File Types", systemImage: "doc.badge.gearshape") }
            BrowserSettings().tabItem { Label("Browser Extensions", systemImage: "puzzlepiece.extension") }
            VideoSettings().tabItem { Label("Video", systemImage: "film") }
            NASSettings().tabItem { Label("NAS", systemImage: "externaldrive.connected.to.line.below") }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(settings.downloadDirectory).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: settings.downloadDirectory)) }
                        Button("Choose…") { chooseDirectory() }
                    }
                }
                Toggle("Organize downloads into category subfolders (Video, Music, Archives…)", isOn: $settings.organizeByCategory)
            }
            Section("Connections") {
                Slider(value: Binding(get: { Double(settings.segmentCount) },
                                      set: { settings.segmentCount = Int($0) }), in: 1...16, step: 1) {
                    Text("Connections per download: \(settings.segmentCount)")
                }
                Text("Each file is downloaded with up to this many parallel connections (4–10 recommended).")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Concurrent downloads: \(settings.maxConcurrent)", value: $settings.maxConcurrent, in: 1...10)
            }
            Section("Behaviour") {
                Toggle("Start new downloads immediately", isOn: $settings.autoStart)
                Toggle("Show a notification when a download completes", isOn: $settings.notifyOnComplete)
                Toggle("Open the download window when a download starts", isOn: $settings.showDetailOnStart)
                Toggle("Close the download window automatically when completed", isOn: $settings.autoCloseDetail)
                Toggle("Watch the clipboard for links and ask to download them", isOn: $settings.watchClipboard)
                Text("Only links that point to a captured file type trigger the prompt. You can also paste a link into the main window with ⌘V.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in toggleLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Start in the menu bar without opening the main window", isOn: $settings.startInMenuBar)
                Toggle("Hide the Dock icon while the main window is closed", isOn: $settings.hideDockIcon)
                    .onChange(of: settings.hideDockIcon) { _ in AppPresence.shared.applyDockPreference() }
                Text("The app keeps running in the menu bar so browser extensions can hand over downloads at any time. Closing the window does not quit; use Quit from the menu bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates automatically (GitHub Releases)", isOn: $settings.checkForUpdates)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current version: \(UpdateChecker.currentVersion)")
                        if let v = updater.latestVersion {
                            Text("Latest release: \(v)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let d = updater.lastCheck {
                            Text("Last checked: \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let e = updater.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    Button(updater.checking ? "Checking…" : "Check Now") { updater.check(interactive: true) }
                        .disabled(updater.checking)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if p.runModal() == .OK, let u = p.url { settings.downloadDirectory = u.path }
    }

    private func toggleLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

// MARK: - File types

struct FileTypesSettings: View {
    var body: some View {
        Form {
            Section("Captured file types") {
                Text("Browser downloads and copied links with these extensions are handed to the app. Everything else stays in the browser.")
                    .font(.caption).foregroundStyle(.secondary)
                CaptureTypesEditor()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Browser extensions

struct BrowserSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @State private var safariEnabled: Bool?
    @State private var browsers = BrowserIntegration.installedBrowsers

    var body: some View {
        Form {
            Section("Browser extensions") {
                Text("The guided setup walks you through each installed browser one at a time: Safari (built in, just enable it), Google Chrome, Brave and Opera (loaded from a folder), Firefox (signed add-on, one click).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { ExtensionWizardWindow.shared.show(server: server) } label: {
                        Label("Open Setup Wizard…", systemImage: "wand.and.stars")
                    }
                    Button("Refresh Status") { refresh() }
                }
                ForEach(browsers) { b in
                    HStack(spacing: 10) {
                        if let icon = b.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                        Text(b.name)
                        Spacer()
                        statusLabel(for: b)
                    }
                }
                HStack {
                    Text(BrowserIntegration.pluginsRoot.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show Plugin Folder") {
                        try? FileManager.default.createDirectory(at: BrowserIntegration.pluginsRoot, withIntermediateDirectories: true)
                        BrowserIntegration.revealInFinder(BrowserIntegration.pluginsRoot)
                    }
                }
            }
            Section("Sites left to the browser") {
                Text("Downloads from these sites are not captured; the browser downloads them itself. Add a site from the extension's menu (“Leave this site's downloads to the browser”) or when a download fails.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.browserOnlySites.isEmpty {
                    Text("No sites").foregroundStyle(.secondary)
                }
                ForEach(settings.browserOnlySites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button(role: .destructive) { settings.setBrowserOnly(site, false) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Capture downloads from this site again")
                    }
                }
            }
            Section("Local bridge") {
                HStack {
                    TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                        .frame(width: 90)
                    Circle().fill(server.running ? .green : .red).frame(width: 8, height: 8)
                    Text(server.statusText).font(.caption).foregroundStyle(.secondary)
                }
                Text("The extension uses port 48213 by default. If you change it here, enter the same port in the extension settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        // Keep the status live: the wizard, Safari and the extensions change it while this pane is open.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder
    private func statusLabel(for b: BrowserIntegration.Kind) -> some View {
        let connected = server.isExtensionConnected(b.rawValue, within: 3600)
        if b == .safari {
            if safariEnabled == true {
                Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if safariEnabled == false {
                Label("Not enabled", systemImage: "circle.dashed").foregroundStyle(.secondary)
            } else {
                Text("…").foregroundStyle(.secondary)
            }
        } else if connected && server.isExtensionOutdated(b.rawValue) {
            HStack(spacing: 8) {
                Label("Update needed (\(server.extensionVersions[b.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? "?") → \(BrowserIntegration.bundledExtensionVersion))",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(b == .firefox ? "Add to Firefox" : "Open Extensions Page") {
                    if b == .firefox { BrowserIntegration.installFirefoxAddon() } else {
                        if !BrowserIntegration.filesUpToDate(for: b) { try? BrowserIntegration.prepareFiles(for: b) }
                        BrowserIntegration.openExtensionsPage(in: b)
                    }
                }
            }
        } else if connected {
            Label("Connected (\(server.extensionVersions[b.rawValue] ?? ""))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if b.isChromium && BrowserIntegration.filesPrepared(for: b) && !BrowserIntegration.filesUpToDate(for: b) {
            Label("Files from an older version", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if BrowserIntegration.filesPrepared(for: b) {
            Label("Files prepared, not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
        } else {
            Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        browsers = BrowserIntegration.installedBrowsers
        Task {
            let state = await BrowserIntegration.safariExtensionEnabled()
            await MainActor.run { safariEnabled = state }
        }
    }
}

// MARK: - Video

struct VideoSettings: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var login = SiteLoginManager.shared
    @ObservedObject private var installer = ToolInstaller.shared

    var body: some View {
        Form {
            Section("Site login (YouTube age verification, members-only videos)") {
                Text("Some videos require a signed-in account. Sign in once in the built-in browser window; the saved cookies are passed to yt-dlp for video downloads. Downloads started from the browser extension already carry the browser's cookies.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if login.cookieCount > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in: \(login.domains.prefix(4).joined(separator: ", "))")
                            if let d = login.savedAt {
                                Text("\(login.cookieCount) cookies saved \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign in to YouTube…") { login.openLogin() }
                    Button("Clear") { login.clear() }.disabled(login.cookieCount == 0)
                }
            }
            Section("yt-dlp") {
                HStack {
                    if let found = VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let v = installer.installedVersion {
                                Text("yt-dlp \(v)")
                            } else {
                                Text("yt-dlp")
                            }
                            Text(found).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text("yt-dlp not found").foregroundStyle(.red)
                    }
                    Spacer()
                    Button(installer.busy ? "Installing…" : (VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) == nil ? "Install yt-dlp" : "Update yt-dlp")) {
                        installer.installOrUpdateYtDlp { _ in installer.refreshVersion(custom: settings.ytdlpPath) }
                    }
                    .disabled(installer.busy)
                }
                if installer.busy {
                    ProgressView(value: installer.progress).progressViewStyle(.linear)
                }
                if let m = installer.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                Text("yt-dlp and ffmpeg are bundled with the app. “Update” downloads the latest yt-dlp release from GitHub into Application Support and uses it instead of the bundled copy. Update when YouTube downloads stop working.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Custom yt-dlp path (empty = bundled)", text: $settings.ytdlpPath)
                    Button("Choose…") { chooseYtDlp() }
                }
                HStack {
                    if let deno = VideoDownloader.locateDeno() {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installer.denoVersion ?? "deno")
                            Text(deno).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text("deno not installed (needed for YouTube)").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(VideoDownloader.locateDeno() == nil ? "Install deno" : "Update deno") {
                        installer.installDeno { _ in installer.refreshVersion(custom: settings.ytdlpPath) }
                    }
                    .disabled(installer.busy)
                }
                Text("YouTube requires a JavaScript runtime to unlock video streams. deno is downloaded from its official GitHub releases (checksum verified) into Application Support.")
                    .font(.caption).foregroundStyle(.secondary)
                if let ff = VideoDownloader.locateFfmpeg() {
                    Text("ffmpeg: \(ff)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("ffmpeg not found (merging video and audio will not work)").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Default format") {
                Picker("Container", selection: $settings.videoContainer) {
                    Text("MP4 (H.264/AAC, plays everywhere)").tag("mp4")
                    Text("MKV").tag("mkv")
                    Text("WebM").tag("webm")
                    Text("Original (no conversion)").tag("original")
                }
                Picker("Maximum resolution", selection: $settings.videoMaxHeight) {
                    Text("Best available").tag(0)
                    Text("2160p (4K)").tag(2160)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("480p").tag(480)
                    Text("360p").tag(360)
                    Divider()
                    Text("Audio only (M4A)").tag(-1)
                    Text("Audio only (MP3)").tag(-2)
                }
                Text("Default: MP4 at up to 1080p. Streams are merged with the bundled ffmpeg.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Custom yt-dlp -f expression (overrides the pickers)", text: $settings.videoFormat)
                Text("Effective arguments: \(settings.ytdlpFormatArguments.joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { installer.refreshVersion(custom: settings.ytdlpPath) }
    }

    private func chooseYtDlp() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { settings.ytdlpPath = u.path }
    }
}

// MARK: - NAS

struct NASSettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var syncing = false
    @State private var syncMessage: String?

    var body: some View {
        Form {
            Section("NAS") {
                Toggle("Download to NAS", isOn: $settings.nasEnabled)
                Toggle("Sync previously downloaded local files to NAS", isOn: $settings.nasSyncExistingLocal)
                Text("Downloads are first completed to your local folder and then automatically uploaded to your NAS. Files already present on the NAS are skipped, and category folders (e.g. Video) are only created on the NAS when needed and if they do not already exist.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(syncing ? "Checking & Uploading to NAS…" : "Check Local Files & Upload Missing to NAS") {
                        runLocalSync()
                    }
                    .disabled(syncing || settings.nasHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let msg = syncMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Section("Connection") {
                Picker("Protocol", selection: $settings.nasProtocol) {
                    Text("SMB").tag("smb")
                    Text("SFTP").tag("sftp")
                    Text("FTP").tag("ftp")
                    Text("WebDAV").tag("webdav")
                }
                TextField("NAS IP / Hostname", text: $settings.nasHost, prompt: Text("192.168.1.100"))
                TextField("Port (0 = default)", value: $settings.nasPort, format: .number.grouping(.never))
                TextField("Username", text: $settings.nasUser)
                SecureField("Password", text: $settings.nasPass)
                TextField("Remote path", text: $settings.nasPath, prompt: Text("/downloads"))
                Text("For SMB, the first folder is the share name (e.g. /downloads or /downloads/movies). Default ports: SMB 445, SFTP 22, FTP 21, WebDAV 443.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") {
                        runTest()
                    }
                    .disabled(testing || settings.nasHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let res = testResult {
                        Label(res.message, systemImage: res.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(res.ok ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runLocalSync() {
        guard let cfg = NASConfig.from([
            "protocol": settings.nasProtocol,
            "host": settings.nasHost,
            "port": settings.nasPort,
            "user": settings.nasUser,
            "pass": settings.nasPass,
            "path": settings.nasPath,
        ]) else {
            syncMessage = String(localized: "Invalid NAS host or path")
            return
        }
        syncing = true
        syncMessage = String(localized: "Checking NAS files…")
        let localRoot = URL(fileURLWithPath: settings.downloadDirectory)
        let organize = settings.organizeByCategory
        NASUploader.syncLocalFiles(
            localRoot: localRoot,
            baseConfig: cfg,
            organizeByCategory: organize,
            onStatus: { current in
                DispatchQueue.main.async {
                    syncMessage = current
                }
            },
            completion: { uploaded, skipped, failed in
                DispatchQueue.main.async {
                    syncing = false
                    syncMessage = String(localized: "NAS sync complete: \(uploaded) uploaded, \(skipped) already on NAS, \(failed) failed ✓")
                }
            }
        )
    }

    private func runTest() {
        guard let cfg = NASConfig.from([
            "protocol": settings.nasProtocol,
            "host": settings.nasHost,
            "port": settings.nasPort,
            "user": settings.nasUser,
            "pass": settings.nasPass,
            "path": settings.nasPath,
        ]) else {
            testResult = (false, String(localized: "Invalid NAS host or path"))
            return
        }
        testing = true
        testResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let res = NASUploader.testConnection(cfg)
            DispatchQueue.main.async {
                testing = false
                if res.ok {
                    testResult = (true, String(localized: "Connection successful ✓"))
                } else {
                    testResult = (false, res.error ?? String(localized: "Connection failed"))
                }
            }
        }
    }
}
