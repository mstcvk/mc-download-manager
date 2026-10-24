import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct NewDownloadRequest {
    var url: URL
    var fileName: String?
    var referer: String?
    var userAgent: String?
    var cookieHeader: String?
    var cookies: [[String: Any]]?
    var kind: DownloadKind = .file
    var extraHeaders: [String: String] = [:]
    var segments: Int? = nil
    var sourceBrowser: String? = nil

    init(url: URL) { self.url = url }
}

/// Tüm indirmelerin durumu, kuyruk ve kalıcılık. Yalnızca ana iş parçacığında kullanılır.
final class DownloadStore: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    let settings: AppSettings
    private var downloaders: [UUID: SegmentedDownloader] = [:]
    private var videoProcesses: [UUID: Process] = [:]
    /// yt-dlp downloads several files (video, audio): bytes completed in earlier phases + approx total.
    private var videoPhase: [UUID: (base: Int64, lastDownloaded: Int64, approxTotal: Int64)] = [:]
    /// YouTube downloads waiting for the deno install prompt / install to finish.
    private var denoWaiters: [UUID] = []
    private var denoPrompting = false
    private var denoDeclinedThisLaunch = false
    /// Video downloads that are retried without cookies after YouTube rejected the signed-in client.
    private var cookielessVideos: Set<UUID> = []
    /// Failed downloads waiting for the "download in the browser instead?" prompt.
    private var handOffQueue: [UUID] = []
    private var handOffPrompting = false
    /// Hosts the extensions must leave to the browser for a short while (a download handed back to the browser).
    private var browserBypass: [String: Date] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var tickCount = 0
    private let supportDir: URL
    private let storeURL: URL

    init(settings: AppSettings) {
        self.settings = settings
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportDir = base.appendingPathComponent("MC Download Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        storeURL = supportDir.appendingPathComponent("downloads.json")
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - Sorgular

    /// Final folder for an item: base folder, plus a category subfolder when enabled.
    func destinationDirectory(for item: DownloadItem) -> URL {
        guard settings.organizeByCategory else { return item.directory }
        return item.directory.appendingPathComponent(item.category.label, isDirectory: true)
    }

    func destinationURL(for item: DownloadItem) -> URL {
        destinationDirectory(for: item).appendingPathComponent(item.fileName)
    }

    var activeCount: Int { items.filter { $0.state.isActive }.count }
    /// Byte-weighted progress of active downloads with a known size (nil when nothing measurable is running).
    var overallProgress: Double? {
        let measurable = items.filter { $0.state.isActive && $0.totalBytes > 0 }
        guard !measurable.isEmpty else { return nil }
        let total = measurable.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = measurable.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
        return total > 0 ? Double(received) / Double(total) : nil
    }

    /// Touches the download folder so macOS asks for Downloads-folder access now (first run / setup),
    /// not in the middle of the first download — where the system prompt pushed the download window behind the browser.
    func prepareDownloadFolder() {
        let dir = URL(fileURLWithPath: settings.downloadDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }
    var totalSpeed: Double { items.filter { $0.state == .downloading }.reduce(0) { $0 + $1.speed } }

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func update(_ id: UUID, _ mutate: (inout DownloadItem) -> Void) {
        guard let i = index(of: id) else { return }
        var item = items[i]
        mutate(&item)
        items[i] = item
    }

    // MARK: - Ekleme

    @discardableResult
    func add(_ req: NewDownloadRequest) -> DownloadItem {
        var headers = req.extraHeaders
        if let r = req.referer, !r.isEmpty { headers["Referer"] = r }
        if let ua = req.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let c = req.cookieHeader, !c.isEmpty { headers["Cookie"] = c }
        if headers["User-Agent"] == nil { headers["User-Agent"] = Self.defaultUserAgent }

        var name = req.fileName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fileName(from: req.url)
        if req.kind == .video { name = req.url.host ?? "video" }
        name = Self.sanitize(name)

        var item = DownloadItem(url: req.url, fileName: name,
                                directory: URL(fileURLWithPath: settings.downloadDirectory),
                                kind: req.kind)
        item.headers = headers
        item.requestedSegments = req.segments ?? 0
        item.sourceBrowser = req.sourceBrowser
        if req.kind == .video, let cookies = req.cookies, !cookies.isEmpty {
            item.cookieFile = writeCookieFile(cookies, id: item.id)
        }
        try? FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
        items.insert(item, at: 0)
        scheduleSave()
        if settings.autoStart { pumpQueue() }
        if settings.showDetailOnStart { DetailWindowManager.shared.show(id: item.id, store: self) }
        return item
    }

    func addURLs(_ text: String, kind: DownloadKind, segments: Int? = nil) {
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { continue }
            var r = NewDownloadRequest(url: url)
            r.kind = kind
            r.segments = segments
            add(r)
        }
    }

    // MARK: - Kuyruk

    func pumpQueue() {
        var slots = max(0, settings.maxConcurrent - activeCount)
        for item in items.reversed() where item.state == .queued && slots > 0 {
            startItem(item.id)
            slots -= 1
        }
    }

    private func startItem(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        if item.kind == .video { startVideo(item) } else { startFile(item) }
    }

    private func startFile(_ item: DownloadItem) {
        let resumable = item.supportsRanges && item.totalBytes > 0 && !item.segments.isEmpty
            && FileManager.default.fileExists(atPath: item.partURL.path)
        var cfg = SegmentedDownloader.Configuration(
            url: item.url, headers: item.headers, partURL: item.partURL,
            segmentCount: item.requestedSegments > 0 ? item.requestedSegments : settings.segmentCount)
        if resumable {
            cfg.resumeSegments = item.segments
            cfg.resumeTotal = item.totalBytes
        }
        let dl = SegmentedDownloader(configuration: cfg)
        let id = item.id
        dl.onProbe = { [weak self, weak dl] probe in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.handleProbe(id: id, probe)
            }
        }
        dl.onProgress = { [weak self, weak dl] received, segs in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.update(id) {
                    $0.receivedBytes = received
                    $0.segments = segs
                    if $0.state == .probing { $0.state = .downloading }
                }
            }
        }
        dl.onFinish = { [weak self, weak dl] result in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.handleFinish(id: id, result)
            }
        }
        downloaders[id] = dl
        update(id) {
            $0.state = resumable ? .downloading : .probing
            $0.errorMessage = nil
            $0.speed = 0
            if !resumable { $0.receivedBytes = 0; $0.segments = [] }
        }
        dl.start()
    }

    private func handleProbe(id: UUID, _ p: ProbeResult) {
        update(id) { item in
            item.totalBytes = p.totalBytes
            item.supportsRanges = p.supportsRanges
            item.state = .downloading
            if let n = p.suggestedFileName, !n.isEmpty {
                item.fileName = Self.sanitize(n)
            } else if let final = p.finalURL, item.fileName == Self.sanitize(Self.fileName(from: item.url)), final != item.url {
                let candidate = Self.fileName(from: final)
                if !(candidate as NSString).pathExtension.isEmpty { item.fileName = Self.sanitize(candidate) }
            }
            if (item.fileName as NSString).pathExtension.isEmpty,
               let ct = p.contentType, let ext = UTType(mimeType: ct)?.preferredFilenameExtension, ext != "bin" {
                item.fileName += "." + ext
            }
        }
    }

    private func handleFinish(id: UUID, _ result: Result<Void, Error>) {
        downloaders[id] = nil
        switch result {
        case .success:
            guard let i = index(of: id) else { return }
            var item = items[i]
            let destDir = destinationDirectory(for: item)
            let dest = Self.uniqueDestination(for: destDir.appendingPathComponent(item.fileName))
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.partURL, to: dest)
                Self.applyQuarantine(to: dest, source: item.url)
                item.fileName = dest.lastPathComponent
                item.finalPath = dest.path
                item.state = .completed
                item.completedAt = Date()
                item.speed = 0
                if item.totalBytes <= 0 { item.totalBytes = item.receivedBytes }
                items[i] = item
                notifyCompleted(item)
                DetailWindowManager.shared.didComplete(id: id, autoClose: settings.autoCloseDetail)
            } catch {
                item.state = .failed
                item.errorMessage = error.localizedDescription
                items[i] = item
            }
        case .failure(let e):
            if let h = e as? HTTPStatusError { update(id) { $0.lastHTTPStatus = h.status } }
            guard let item = items.first(where: { $0.id == id }), item.state != .paused, item.state != .cancelled else { break }
            update(id) {
                $0.state = .failed
                $0.errorMessage = e.localizedDescription
                $0.speed = 0
            }
            if Self.browserMightHelp(e) { offerBrowserHandOff(id) }
        }
        scheduleSave()
        pumpQueue()
    }

    // MARK: - Hand-off to the browser

    /// Server refusals and odd responses: a browser (its own cookies, one connection, the site's own flow) may succeed.
    /// Local problems (disk, no network) would fail there too.
    private static func browserMightHelp(_ error: Error) -> Bool {
        if error is HTTPStatusError { return true }
        let e = error as NSError
        if let f = error as? DownloadFailure { return !f.local }
        guard e.domain == NSURLErrorDomain else { return false }
        return ![NSURLErrorNotConnectedToInternet, NSURLErrorCancelled, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile].contains(e.code)
    }

    /// Hosts the browser extensions must not capture right now (see `/ping`).
    var bypassHosts: [String] {
        let now = Date()
        browserBypass = browserBypass.filter { $0.value > now }
        return Array(browserBypass.keys)
    }

    /// The site a download belongs to: the page it was started from, else its own host.
    static func siteHost(of item: DownloadItem) -> String? {
        AppSettings.siteKey(item.referer?.host ?? item.url.host)
    }

    private func offerBrowserHandOff(_ id: UUID) {
        if !handOffQueue.contains(id) { handOffQueue.append(id) }
        guard !handOffPrompting else { return }
        handOffPrompting = true
        DispatchQueue.main.async { [weak self] in self?.promptNextHandOff() }
    }

    private func promptNextHandOff() {
        guard !handOffQueue.isEmpty else { handOffPrompting = false; return }
        let id = handOffQueue.removeFirst()
        guard let item = items.first(where: { $0.id == id }), item.state == .failed else { promptNextHandOff(); return }
        let site = Self.siteHost(of: item) ?? item.url.absoluteString
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Download in the browser instead?")
        alert.informativeText = String(localized: "“\(item.fileName)” could not be downloaded: \(item.errorMessage ?? "")\n\nSome sites (for example WeTransfer) only allow their downloads in a browser. MC Download Manager can hand this download back to the browser.")
        alert.addButton(withTitle: String(localized: "Download in Browser"))
        alert.addButton(withTitle: String(localized: "Retry Here"))
        alert.addButton(withTitle: String(localized: "Close")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Always leave downloads from \(site) to the browser")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let always = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
            handOffToBrowser(id)
        case .alertSecondButtonReturn:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
            resume(id)
        default:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
        }
        promptNextHandOff()
    }

    private static let browserBundleIDs = [
        "chrome": "com.google.Chrome", "brave": "com.brave.Browser", "opera": "com.operasoftware.Opera", "edge": "com.microsoft.edgemac",
        "firefox": "org.mozilla.firefox", "safari": "com.apple.Safari",
    ]

    /// Opens the download in the browser it came from and lets the extension pass it through for a few minutes.
    func handOffToBrowser(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let until = Date().addingTimeInterval(180)
        for host in [item.url.host, item.referer?.host] { if let k = AppSettings.siteKey(host) { browserBypass[k] = until } }
        // A refused signed link is usually spent (one-shot token): reopen the page so the site issues a fresh one.
        var target = item.url
        if let status = item.lastHTTPStatus, [401, 403, 404, 410].contains(status),
           let page = item.referer, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            target = page
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let bid = item.sourceBrowser.flatMap({ Self.browserBundleIDs[$0] }),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open([target], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(target)
        }
        remove(id)
    }

    // MARK: - Video (yt-dlp)

    private func startVideo(_ item: DownloadItem) {
        let id = item.id
        guard let exe = VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) else {
            update(id) {
                $0.state = .failed
                $0.errorMessage = String(localized: "yt-dlp not found. Use “Install yt-dlp” in Settings ▸ Video.")
            }
            pumpQueue()
            return
        }
        if VideoDownloader.isYouTube(item.url), VideoDownloader.locateDeno() == nil,
           !settings.denoPromptSuppressed, !denoDeclinedThisLaunch {
            update(id) { $0.state = .downloading; $0.errorMessage = nil; $0.speed = 0; $0.stage = String(localized: "Waiting for the JavaScript runtime (deno)…") }
            if !denoWaiters.contains(id) { denoWaiters.append(id) }
            if !denoPrompting {
                denoPrompting = true
                DispatchQueue.main.async { [weak self] in self?.promptForDeno() }
            }
            return
        }
        let useCookies = !cookielessVideos.contains(id)
        update(id) {
            $0.state = .downloading; $0.errorMessage = nil; $0.receivedBytes = 0; $0.speed = 0; $0.totalBytes = -1
            $0.stage = String(localized: "Fetching video information…")
            if useCookies { $0.log = "" }   // keep the failed attempt's output visible above the retry
        }
        let outDir = destinationDirectory(for: item)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let proc = VideoDownloader.run(
            executable: exe, url: item.url, outputDir: outDir, formatArgs: settings.ytdlpFormatArguments,
            headers: item.headers, cookieFile: item.cookieFile, useCookies: useCookies,
            onProgress: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var ph = self.videoPhase[id] ?? (0, 0, -1)
                    if p.downloaded < ph.lastDownloaded { ph.base += ph.lastDownloaded }   // new file started
                    ph.lastDownloaded = p.downloaded
                    self.videoPhase[id] = ph
                    let received = ph.base + p.downloaded
                    self.update(id) {
                        $0.receivedBytes = received
                        let phaseTotal = p.total > 0 ? ph.base + p.total : -1
                        $0.totalBytes = max(ph.approxTotal, phaseTotal, received)
                        $0.speed = p.speed
                    }
                }
            },
            onLine: { [weak self] line in
                DispatchQueue.main.async {
                    self?.update(id) {
                        $0.log = String(($0.log + line + "\n").suffix(6000))
                        if let st = VideoDownloader.stage(for: line) { $0.stage = st }
                        if line.hasPrefix("MCFMT|"), let n = Double(line.split(separator: "|", omittingEmptySubsequences: false).dropFirst(5).first ?? ""), n > 0 {
                            var ph = self?.videoPhase[id] ?? (0, 0, -1)
                            ph.approxTotal = Int64(n)
                            self?.videoPhase[id] = ph
                            if $0.totalBytes < Int64(n) { $0.totalBytes = Int64(n) }
                        }
                        if let r = line.range(of: "Destination: ") {
                            // Show the final title; strip yt-dlp's intermediate ".f137" format suffix.
                            var name = URL(fileURLWithPath: String(line[r.upperBound...])).lastPathComponent
                            if let m = name.range(of: "\\.f[0-9]+[-a-z0-9]*(?=\\.[a-z0-9]+$)", options: .regularExpression) { name.removeSubrange(m) }
                            $0.fileName = name
                        }
                        if line.hasPrefix("[Merger] Merging formats into \""), let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                            $0.fileName = URL(fileURLWithPath: String(line[line.index(after: q1)..<q2])).lastPathComponent
                        }
                    }
                }
            },
            onFinish: { [weak self] result in
                DispatchQueue.main.async { self?.handleVideoFinish(id: id, result) }
            })
        videoProcesses[id] = proc
        videoPhase[id] = (0, 0, -1)
    }

    private func handleVideoFinish(id: UUID, _ result: Result<String?, Error>) {
        videoProcesses[id] = nil
        videoPhase[id] = nil
        guard let i = index(of: id) else { return }
        var item = items[i]
        guard item.state == .downloading else { return }   // kullanıcı duraklattı/iptal etti
        switch result {
        case .success(let path):
            item.state = .completed
            item.completedAt = Date()
            item.speed = 0
            if let path = path.map(Self.removingVideoID) {
                item.finalPath = path
                item.fileName = URL(fileURLWithPath: path).lastPathComponent
                Self.applyQuarantine(to: URL(fileURLWithPath: path), source: item.url)
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                    item.totalBytes = size
                    item.receivedBytes = size
                }
            } else if item.totalBytes > 0 {
                item.receivedBytes = item.totalBytes
            }
            items[i] = item
            notifyCompleted(item)
            DetailWindowManager.shared.didComplete(id: id, autoClose: settings.autoCloseDetail)
        case .failure(let e):
            if !cookielessVideos.contains(id), VideoDownloader.isYouTube(item.url),
               VideoDownloader.isSignedInClientFailure(e.localizedDescription),
               VideoDownloader.hasCookies(itemCookies: item.cookieFile, targetHost: item.url.host) {
                cookielessVideos.insert(id)
                item.log += String(localized: "→ YouTube rejected the signed-in request; retrying without cookies…") + "\n"
                items[i] = item
                startVideo(item)
                return
            }
            item.state = .failed
            item.errorMessage = e.localizedDescription
            item.speed = 0
            items[i] = item
        }
        scheduleSave()
        pumpQueue()
    }

    /// Asks once whether to install deno, which yt-dlp needs for YouTube, then starts the waiting downloads.
    private func promptForDeno() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Install the JavaScript runtime for YouTube?")
        alert.informativeText = String(localized: "YouTube now requires yt-dlp to run JavaScript (deno) to unlock video streams. Without it, YouTube downloads may fail with errors such as “The page needs to be reloaded” or “n challenge solving failed”.\n\nMC Download Manager can download deno (\(ToolInstaller.denoDownloadSize)) from its official GitHub releases and keep it in its own Application Support folder.")
        alert.addButton(withTitle: String(localized: "Install deno"))
        alert.addButton(withTitle: String(localized: "Not Now")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.denoPromptSuppressed = true }
        guard response == .alertFirstButtonReturn else {
            denoDeclinedThisLaunch = true
            resumeDenoWaiters()
            return
        }
        for id in denoWaiters { update(id) { $0.stage = String(localized: "Installing deno…") } }
        ToolInstaller.shared.installDeno { [weak self] result in
            guard let self else { return }
            if case .failure(let e) = result {
                self.denoDeclinedThisLaunch = true   // don't loop on a failing install; Settings ▸ Video can retry
                for id in self.denoWaiters {
                    self.update(id) { $0.log += String(localized: "deno could not be installed: \(e.localizedDescription)") + "\n" }
                }
            }
            self.resumeDenoWaiters()
        }
    }

    private func resumeDenoWaiters() {
        denoPrompting = false
        let waiting = denoWaiters
        denoWaiters = []
        for id in waiting {
            guard let item = items.first(where: { $0.id == id }), item.state == .downloading else { continue }
            startVideo(item)
        }
    }

    // MARK: - Kullanıcı eylemleri

    func pause(_ id: UUID) {
        guard let i = index(of: id), items[i].state.isActive || items[i].state == .queued else { return }
        update(id) { $0.state = .paused; $0.speed = 0 }
        downloaders[id]?.stop()
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        scheduleSave()
        pumpQueue()
    }

    func resume(_ id: UUID) {
        guard let i = index(of: id), [.paused, .failed, .cancelled].contains(items[i].state) else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil; $0.lastHTTPStatus = nil }
        cookielessVideos.remove(id)
        pumpQueue()
    }

    /// Starts a download that is waiting in the queue (added while "Start new downloads immediately" is off),
    /// as soon as a connection slot is free.
    func start(_ id: UUID) {
        guard let i = index(of: id), items[i].state == .queued else { return }
        if activeCount < settings.maxConcurrent { startItem(id) }
    }

    func cancel(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        if let dl = downloaders.removeValue(forKey: id) { dl.stop() }
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        try? FileManager.default.removeItem(at: item.partURL)
        update(id) { $0.state = .cancelled; $0.speed = 0; $0.receivedBytes = 0; $0.segments = [] }
        scheduleSave()
        pumpQueue()
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        if let dl = downloaders.removeValue(forKey: id) { dl.stop() }
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        try? FileManager.default.removeItem(at: item.partURL)
        if let cf = item.cookieFile { try? FileManager.default.removeItem(atPath: cf) }
        if deleteFile, let fp = item.finalPath, FileManager.default.fileExists(atPath: fp) {
            // Always move to Trash so the user can recover the file.
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: fp), resultingItemURL: nil)
        }
        items.remove(at: i)
        samples[id] = nil
        scheduleSave()
        pumpQueue()
    }

    func pauseAll() { items.filter { $0.state.isActive || $0.state == .queued }.forEach { pause($0.id) } }
    func resumeAll() {
        items.filter { [.paused, .failed].contains($0.state) }.forEach { resume($0.id) }
        pumpQueue()   // also starts downloads added while "Start new downloads immediately" is off
    }
    func clearFinished() {
        items.filter { [.completed, .cancelled].contains($0.state) }.forEach { remove($0.id) }
    }

    func revealInFinder(_ item: DownloadItem) {
        if let fp = item.finalPath, FileManager.default.fileExists(atPath: fp) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fp)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([destinationDirectory(for: item)])
        }
    }

    func open(_ item: DownloadItem) {
        guard let fp = item.finalPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: fp))
    }

    func shutdown() {
        pauseAll()
        save()
    }

    // MARK: - Hız ölçümü

    private func tick() {
        let now = Date()
        var activeIDs = Set<UUID>()
        for i in items.indices where items[i].state == .downloading && items[i].kind != .video {
            let id = items[i].id
            activeIDs.insert(id)
            let bytes = items[i].receivedBytes
            if let s = samples[id] {
                let dt = now.timeIntervalSince(s.time)
                if dt > 0 {
                    let inst = max(0, Double(bytes - s.bytes) / dt)
                    items[i].speed = items[i].speed == 0 ? inst : items[i].speed * 0.6 + inst * 0.4
                }
            }
            samples[id] = (bytes, now)
        }
        samples = samples.filter { activeIDs.contains($0.key) }
        DetailWindowManager.shared.refreshTitles(items: items)
        tickCount += 1
        if !activeIDs.isEmpty, tickCount % 10 == 0 { save() }   // parça durumu 5 sn'de bir diske
    }

    // MARK: - Kalıcılık

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var arr = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        for i in arr.indices {
            if arr[i].state.isActive || arr[i].state == .queued { arr[i].state = .paused }
            arr[i].speed = 0
        }
        items = arr
        cleanupOrphanParts()
    }

    /// Listede olmayan indirmelerden kalan `.dm-<id>.part` dosyalarını siler.
    private func cleanupOrphanParts() {
        let dir = URL(fileURLWithPath: settings.downloadDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let known = Set(items.map { ".dm-\($0.id.uuidString).part" })
        for n in names where n.hasPrefix(".dm-") && n.hasSuffix(".part") && !known.contains(n) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func writeCookieFile(_ cookies: [[String: Any]], id: UUID) -> String? {
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies {
            guard let name = c["name"] as? String, let value = c["value"] as? String,
                  let domain = c["domain"] as? String else { continue }
            let path = c["path"] as? String ?? "/"
            let secure = (c["secure"] as? Bool ?? false) ? "TRUE" : "FALSE"
            let exp = Int64((c["expirationDate"] as? Double) ?? 0)
            let flag = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            lines.append([domain, flag, path, secure, String(exp), name, value].joined(separator: "\t"))
        }
        let dir = supportDir.appendingPathComponent("cookies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).txt")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Bildirim

    private func notifyCompleted(_ item: DownloadItem) {
        guard settings.notifyOnComplete, Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Download completed")
        content.body = item.fileName
        content.sound = .default
        let req = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Tags a downloaded file like a browser download would, so Gatekeeper/XProtect assess it on first open.
    static func applyQuarantine(to file: URL, source: URL) {
        var target = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "MC Download Manager",
            kLSQuarantineDataURLKey as String: source.absoluteString,
        ]
        try? target.setResourceValues(values)
    }

    // MARK: - Dosya adı yardımcıları

    static func fileName(from url: URL) -> String {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || name == "/" { name = url.host ?? "download" }
        return name
    }

    static func sanitize(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasPrefix(".") { n = "_" + n }
        if n.count > 200 {
            let ext = (n as NSString).pathExtension
            let base = String((n as NSString).deletingPathExtension.prefix(180))
            n = ext.isEmpty ? base : base + "." + ext
        }
        return n.isEmpty ? "download" : n
    }

    /// yt-dlp saves "<title> [<id>].<ext>" so resume and its duplicate check keep working;
    /// once finished, rename it to "<title>.<ext>" ("<title> (2).<ext>" if that name is taken).
    static func removingVideoID(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var name = url.lastPathComponent
        guard let r = name.range(of: " \\[[^\\[\\]]+\\](?=\\.[^.]+$)", options: .regularExpression) else { return path }
        name.removeSubrange(r)
        let dest = uniqueDestination(for: url.deletingLastPathComponent().appendingPathComponent(name))
        return (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest.path : path
    }

    static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
