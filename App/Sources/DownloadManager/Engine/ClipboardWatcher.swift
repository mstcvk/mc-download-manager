import AppKit
import Foundation

/// Watches the system clipboard for HTTP(S) and magnet links and asks the user whether to download them.
/// Also used by the ⌘V paste command in the main window.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var store: DownloadStore?
    private var settings: AppSettings?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var askedURLs: [String] = []
    private var prompting = false

    private static let videoHosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "twitter.com", "x.com",
                                     "instagram.com", "tiktok.com", "twitch.tv", "facebook.com", "reddit.com", "bilibili.com"]

    func start(store: DownloadStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    // MARK: - Clipboard polling

    private func poll() {
        guard let settings, settings.watchClipboard, !prompting else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string) else { return }
        // Only react when the clipboard holds nothing but links, and the links point at files of a captured type.
        guard let onlyURLs = Self.urlOnlyContent(text) else { return }
        let exts = settings.captureExtensions
        let urls = onlyURLs
            .filter { TorrentDownloader.isMagnet($0) || CaptureTypes.matches(url: $0, extensions: exts) }
            .filter { !askedURLs.contains($0.absoluteString) }
        guard !urls.isEmpty else { return }
        remember(urls)
        ask(urls: urls, source: .clipboard)
    }

    /// Called from the ⌘V paste command (explicit user action: any HTTP(S) or valid magnet link is accepted).
    func handlePaste(text: String) {
        guard let urls = Self.urlOnlyContent(text), !urls.isEmpty else { return }
        remember(urls)
        ask(urls: urls, source: .paste)
    }

    private func remember(_ urls: [URL]) {
        askedURLs.append(contentsOf: urls.map(\.absoluteString))
        if askedURLs.count > 50 { askedURLs.removeFirst(askedURLs.count - 50) }
    }

    /// Returns the links if every non-empty line of `text` is a single HTTP(S) URL or magnet link; nil otherwise.
    static func urlOnlyContent(_ text: String) -> [URL]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 50 else { return nil }
        var urls: [URL] = []
        for line in lines {
            guard !line.contains(" "), let url = URL(string: line), TorrentDownloader.accepts(url) else { return nil }
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    static func extractURLs(from text: String) -> [URL] {
        var out: [URL] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let s = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[]{},;"))
            guard let url = URL(string: s), TorrentDownloader.accepts(url) else { continue }
            if !out.contains(url) { out.append(url) }
        }
        return out
    }

    static func looksLikeVideoPage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if FileCategory.detect(fileName: url.lastPathComponent, kind: .file) != .other { return false }
        return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Prompt

    enum Source { case clipboard, paste }

    private func ask(urls: [URL], source: Source) {
        guard let store else { return }
        prompting = true
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        if urls.count == 1 {
            alert.messageText = source == .clipboard
                ? String(localized: "A link was copied. Download it?")
                : String(localized: "Download the pasted link?")
            alert.informativeText = urls[0].absoluteString
        } else {
            alert.messageText = source == .clipboard
                ? String(localized: "\(urls.count) links were copied. Download them?")
                : String(localized: "Download the \(urls.count) pasted links?")
            alert.informativeText = urls.prefix(6).map(\.absoluteString).joined(separator: "\n") + (urls.count > 6 ? "\n…" : "")
        }
        let preferVideo = urls.allSatisfy(Self.looksLikeVideoPage)
        if preferVideo {
            alert.addButton(withTitle: String(localized: "Download Video (yt-dlp)"))
            alert.addButton(withTitle: String(localized: "Download as File"))
        } else {
            alert.addButton(withTitle: String(localized: "Download"))
            alert.addButton(withTitle: String(localized: "Download Video (yt-dlp)"))
        }
        alert.addButton(withTitle: String(localized: "Ignore")).keyEquivalent = "\u{1b}"
        if source == .clipboard {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Stop watching the clipboard")
        }
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        prompting = false
        if alert.suppressionButton?.state == .on { settings?.watchClipboard = false }

        let kind: DownloadKind?
        switch response {
        case .alertFirstButtonReturn: kind = preferVideo ? .video : .file
        case .alertSecondButtonReturn: kind = preferVideo ? .file : .video
        default: kind = nil
        }
        guard let kind else { return }
        for url in urls {
            var r = NewDownloadRequest(url: url)
            r.kind = kind
            store.add(r)
        }
    }
}
