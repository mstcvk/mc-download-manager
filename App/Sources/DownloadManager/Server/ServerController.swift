import Foundation
import Combine
import Network
import AppKit

/// Yerel HTTP köprüsünü yönetir ve istekleri DownloadStore'a çevirir.
final class ServerController: ObservableObject {
    @Published var statusText = String(localized: "Not started")
    @Published var running = false
    /// Last time each browser's extension talked to the bridge (keys: safari, chrome, brave, opera, edge, firefox, other).
    @Published var extensionConnections: [String: Date] = [:]

    /// Version each browser's extension reported last ("" for extensions too old to report one).
    @Published var extensionVersions: [String: String] = [:]

    func isExtensionConnected(_ browser: String, within seconds: TimeInterval = 120) -> Bool {
        guard let d = extensionConnections[browser] else { return false }
        return Date().timeIntervalSince(d) < seconds
    }

    /// The browser's extension talked to the bridge but runs another version than the one this app carries.
    /// Safari's extension is part of the app and always current.
    func isExtensionOutdated(_ browser: String) -> Bool {
        guard browser != "safari", let v = extensionVersions[browser] else { return false }
        return v != BrowserIntegration.bundledExtensionVersion
    }

    private var outdatedPrompted: Set<String> = []
    private var outdatedPromptShowing = false

    /// An outdated extension that reloads itself reports the new version within a ping or two; ask the user only
    /// when it is still outdated a little later (extensions older than this check, Firefox's signed add-on).
    private func checkOutdated(_ browser: String) {
        guard isExtensionOutdated(browser), !outdatedPrompted.contains(browser) else { return }
        outdatedPrompted.insert(browser)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.isExtensionOutdated(browser) else { self?.outdatedPrompted.remove(browser); return }
            self.promptOutdated(browser)
        }
    }

    private func promptOutdated(_ browser: String) {
        guard !outdatedPromptShowing, let kind = BrowserIntegration.Kind(rawValue: browser) else { return }
        outdatedPromptShowing = true
        defer { outdatedPromptShowing = false }
        let old = extensionVersions[browser].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "an older version")
        let new = BrowserIntegration.bundledExtensionVersion
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = kind.icon ?? NSApp.applicationIconImage
        alert.messageText = String(localized: "The \(kind.name) extension is out of date")
        if kind == .firefox {
            alert.informativeText = String(localized: "\(kind.name) runs extension \(old), this app comes with \(new). Install the new add-on: Firefox asks you to confirm.")
            alert.addButton(withTitle: String(localized: "Add to Firefox"))
        } else {
            if BrowserIntegration.filesPrepared(for: kind), !BrowserIntegration.filesUpToDate(for: kind) {
                try? BrowserIntegration.prepareFiles(for: kind)
            }
            alert.informativeText = String(localized: "\(kind.name) runs extension \(old), this app comes with \(new). The extension folder has been updated; click the reload icon (↻) of MC Download Manager on the extensions page, or restart \(kind.name).")
            alert.addButton(withTitle: String(localized: "Open Extensions Page"))
        }
        alert.addButton(withTitle: String(localized: "Later")).keyEquivalent = "\u{1b}"
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if kind == .firefox { BrowserIntegration.installFirefoxAddon() } else { BrowserIntegration.openExtensionsPage(in: kind) }
    }

    private func noteConnection(_ req: HTTPRequest) {
        let browser = Self.browserName(req)
        extensionConnections[browser] = Date()
        let version = req.headers["x-mcdm-extension-version"] ?? ""
        if extensionVersions[browser] != version { extensionVersions[browser] = version }
        checkOutdated(browser)
        // Chromium extension ids may call the native host that launches the app (see NativeHostRegistry).
        var extensionID = req.headers["x-mcdm-extension-id"]
        if let origin = req.headers["origin"], origin.hasPrefix("chrome-extension://") {
            extensionID = String(origin.dropFirst("chrome-extension://".count).prefix { $0 != "/" })
        }
        if let id = extensionID?.lowercased(), NativeHostRegistry.isValidChromiumID(id) {
            DispatchQueue.global(qos: .utility).async { NativeHostRegistry.noteExtensionID(id) }
        }
    }

    /// Which browser's extension sent the request (safari, chrome, brave, opera, edge, firefox, other).
    static func browserName(_ req: HTTPRequest) -> String {
        var browser = "other"
        if let origin = req.headers["origin"] {
            if origin.hasPrefix("safari-web-extension://") { browser = "safari" }
            else if origin.hasPrefix("chrome-extension://") { browser = "chrome" }
            else if origin.hasPrefix("moz-extension://") { browser = "firefox" }
        }
        if let h = req.headers["x-mcdm-extension"]?.lowercased(), ["safari", "chrome", "brave", "opera", "edge", "firefox"].contains(h) { browser = h }
        if let q = req.path.split(separator: "?", maxSplits: 1).last, req.path.contains("?") {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "browser" { browser = String(kv[1]).lowercased() }
            }
        }
        return browser
    }

    private var server: LocalServer?
    private let store: DownloadStore
    private let settings: AppSettings
    private var cancellable: AnyCancellable?

    static let version = "1.4.1"

    init(store: DownloadStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        localServerAllowedOrigin = { Self.originAllowed($0) }
        start()
        cancellable = settings.$serverPort
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.start() }
    }

    func start() {
        server?.stop()
        running = false
        let port = UInt16(clamping: max(1024, min(65535, settings.serverPort)))
        let s = LocalServer(port: port) { [weak self] req, done in
            DispatchQueue.main.async {
                done(self?.handle(req) ?? .json(["ok": false, "error": "shutting down"], status: 500))
            }
        }
        s.onStateChange = { [weak self] st in
            DispatchQueue.main.async {
                switch st {
                case .ready:
                    self?.running = true
                    self?.statusText = String(localized: "Listening on 127.0.0.1:\(String(port))")
                case .failed(let e):
                    self?.running = false
                    self?.statusText = String(localized: "Error: \(e.localizedDescription) (port \(String(port)) may be in use)")
                case .cancelled:
                    self?.running = false
                    self?.statusText = String(localized: "Stopped")
                default:
                    break
                }
            }
        }
        do {
            try s.start()
            server = s
        } catch {
            statusText = String(localized: "Could not start: \(error.localizedDescription)")
        }
    }

    /// Only browser extensions may talk to the bridge. Requests without an Origin, with an
    /// empty Origin or with the opaque "null" origin (sandboxed iframes, data: pages) are rejected,
    /// so ordinary web pages cannot drive the app.
    static func originAllowed(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty, origin != "null" else { return false }
        return origin.hasPrefix("chrome-extension://")
            || origin.hasPrefix("safari-web-extension://")
            || origin.hasPrefix("moz-extension://")
    }

    /// Extension requests either carry an extension Origin (Safari, Chrome POST) or — when Chrome omits the
    /// Origin header for GETs covered by host permissions — no Origin at all plus the X-MCDM-Extension header.
    /// A web page cannot produce the second form: custom headers force a CORS preflight, and the preflight's
    /// Origin is a web origin that is rejected here.
    static func extensionRequest(_ req: HTTPRequest) -> Bool {
        let origin = req.headers["origin"]
        if originAllowed(origin) { return true }
        let hasHeader = !(req.headers["x-mcdm-extension"] ?? "").isEmpty
        return origin == nil && hasHeader
    }

    private func hostAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let port = UInt16(clamping: max(1024, min(65535, settings.serverPort)))
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "[::1]:\(port)"
    }

    private func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard Self.extensionRequest(req), hostAllowed(req.headers["host"]) else {
            return .json(["ok": false, "error": "forbidden"], status: 403)
        }
        if req.method == "OPTIONS" { return .json(["ok": true]) }
        noteConnection(req)
        let path = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.path

        switch (req.method, path) {
        case ("GET", "/ping"):
            return .json([
                "ok": true,
                "app": "MCDownloadManager",
                "version": Self.version,
                "ytdlp": VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) != nil,
                "active": store.items.filter { $0.state.isActive }.count,
                "captureExtensions": settings.captureExtensions,
                // Extensions compare this with their own version and reload themselves (unpacked) when it differs.
                "extensionVersion": BrowserIntegration.bundledExtensionVersion,
                // Downloads from these sites stay in the browser: permanently, or for a few minutes after a hand-off.
                "browserOnlySites": settings.browserOnlySites,
                "bypassHosts": store.bypassHosts,
            ])

        case ("GET", "/downloads"):
            let list: [[String: Any]] = store.items.prefix(50).map {
                [
                    "id": $0.id.uuidString,
                    "name": $0.fileName,
                    "state": $0.state.rawValue,
                    "progress": $0.progress,
                    "speed": $0.speed,
                    "total": $0.totalBytes,
                    "received": $0.receivedBytes,
                    "stage": $0.stage,
                ]
            }
            return .json(["ok": true, "items": list])

        case ("POST", "/download"):
            guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
                  let urlStr = obj["url"] as? String,
                  let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .json(["ok": false, "error": "invalid url"], status: 400)
            }
            var r = NewDownloadRequest(url: url)
            r.fileName = obj["filename"] as? String
            r.referer = obj["referer"] as? String
            r.userAgent = obj["userAgent"] as? String
            r.cookieHeader = obj["cookieHeader"] as? String
            r.cookies = obj["cookies"] as? [[String: Any]]
            r.kind = (obj["kind"] as? String).flatMap(DownloadKind.init(rawValue:)) ?? .file
            if let h = obj["headers"] as? [String: String] { r.extraHeaders = h }
            if let s = obj["segments"] as? Int { r.segments = s }
            let browser = Self.browserName(req)
            if browser != "other" { r.sourceBrowser = browser }
            let item = store.add(r)
            return .json(["ok": true, "id": item.id.uuidString])

        case ("POST", "/site"):
            guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
                  let host = obj["host"] as? String, AppSettings.siteKey(host) != nil,
                  let on = obj["browserOnly"] as? Bool else {
                return .json(["ok": false, "error": "host and browserOnly required"], status: 400)
            }
            settings.setBrowserOnly(host, on)
            return .json(["ok": true, "browserOnlySites": settings.browserOnlySites])

        case ("POST", "/action"):
            guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
                  let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
                  let action = obj["action"] as? String else {
                return .json(["ok": false, "error": "id and action required"], status: 400)
            }
            switch action {
            case "pause": store.pause(id)
            case "resume": store.resume(id)
            case "cancel": store.cancel(id)
            case "remove": store.remove(id)
            default: return .json(["ok": false, "error": "unknown action"], status: 400)
            }
            return .json(["ok": true])

        default:
            return .json(["ok": false, "error": "not found"], status: 404)
        }
    }
}
