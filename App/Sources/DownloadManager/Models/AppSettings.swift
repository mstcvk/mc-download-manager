import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var segmentCount: Int { didSet { defaults.set(segmentCount, forKey: "segmentCount") } }
    @Published var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    @Published var serverPort: Int { didSet { defaults.set(serverPort, forKey: "serverPort") } }
    @Published var downloadDirectory: String { didSet { defaults.set(downloadDirectory, forKey: "downloadDirectory") } }
    @Published var ytdlpPath: String { didSet { defaults.set(ytdlpPath, forKey: "ytdlpPath") } }
    @Published var videoFormat: String { didSet { defaults.set(videoFormat, forKey: "videoFormat") } }   // custom -f (overrides pickers when non-empty)
    @Published var videoContainer: String { didSet { defaults.set(videoContainer, forKey: "videoContainer") } } // mp4 | mkv | webm | original
    @Published var videoMaxHeight: Int { didSet { defaults.set(videoMaxHeight, forKey: "videoMaxHeight") } }   // 0 = best, -1 = audio m4a, -2 = audio mp3
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "autoStart") } }
    @Published var notifyOnComplete: Bool { didSet { defaults.set(notifyOnComplete, forKey: "notifyOnComplete") } }
    @Published var showDetailOnStart: Bool { didSet { defaults.set(showDetailOnStart, forKey: "showDetailOnStart") } }
    @Published var autoCloseDetail: Bool { didSet { defaults.set(autoCloseDetail, forKey: "autoCloseDetail") } }
    @Published var watchClipboard: Bool { didSet { defaults.set(watchClipboard, forKey: "watchClipboard") } }
    @Published var captureGroupIDs: Set<String> { didSet { defaults.set(Array(captureGroupIDs).sorted(), forKey: "captureGroupIDs") } }
    @Published var customExtensions: String { didSet { defaults.set(customExtensions, forKey: "customExtensions") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var organizeByCategory: Bool { didSet { defaults.set(organizeByCategory, forKey: "organizeByCategory") } }
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    /// Keep the main window closed at launch; the app is reachable from the menu bar icon.
    @Published var startInMenuBar: Bool { didSet { defaults.set(startInMenuBar, forKey: "startInMenuBar") } }
    /// Show the Dock icon only while a window is open.
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: "hideDockIcon") } }
    /// One-shot flag: the login item was offered/registered automatically after setup.
    @Published var loginItemAutoRegistered: Bool { didSet { defaults.set(loginItemAutoRegistered, forKey: "loginItemAutoRegistered") } }
    /// The user chose “Don't ask again” on the deno install prompt for YouTube downloads.
    @Published var denoPromptSuppressed: Bool { didSet { defaults.set(denoPromptSuppressed, forKey: "denoPromptSuppressed") } }

    /// Sites whose downloads stay in the browser (hosts without "www."; subdomains match too).
    @Published var browserOnlySites: [String] { didSet { defaults.set(browserOnlySites, forKey: "browserOnlySites") } }

    static func siteKey(_ host: String?) -> String? {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func setBrowserOnly(_ host: String?, _ on: Bool) {
        guard let key = Self.siteKey(host) else { return }
        if on { if !browserOnlySites.contains(key) { browserOnlySites.append(key); browserOnlySites.sort() } }
        else { browserOnlySites.removeAll { $0 == key } }
    }

    /// All file extensions (lowercase, no dot) the app should capture.
    var captureExtensions: [String] { CaptureTypes.extensions(groupIDs: captureGroupIDs, custom: customExtensions) }

    static let defaultDownloadDir: String = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
        return downloads + "/MC Download Manager"
    }()

    private init() {
        segmentCount = defaults.object(forKey: "segmentCount") as? Int ?? 8
        maxConcurrent = defaults.object(forKey: "maxConcurrent") as? Int ?? 3
        serverPort = defaults.object(forKey: "serverPort") as? Int ?? 48213
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? Self.defaultDownloadDir
        ytdlpPath = defaults.string(forKey: "ytdlpPath") ?? ""
        videoFormat = defaults.string(forKey: "videoFormat") ?? ""
        videoContainer = defaults.string(forKey: "videoContainer") ?? "mp4"
        videoMaxHeight = defaults.object(forKey: "videoMaxHeight") as? Int ?? 1080
        autoStart = defaults.object(forKey: "autoStart") as? Bool ?? true
        notifyOnComplete = defaults.object(forKey: "notifyOnComplete") as? Bool ?? true
        showDetailOnStart = defaults.object(forKey: "showDetailOnStart") as? Bool ?? true
        autoCloseDetail = defaults.object(forKey: "autoCloseDetail") as? Bool ?? false
        watchClipboard = defaults.object(forKey: "watchClipboard") as? Bool ?? true
        captureGroupIDs = Set(defaults.stringArray(forKey: "captureGroupIDs") ?? Array(CaptureTypes.defaultGroupIDs))
        customExtensions = defaults.string(forKey: "customExtensions") ?? ""
        onboardingDone = defaults.object(forKey: "onboardingDone") as? Bool ?? false
        organizeByCategory = defaults.object(forKey: "organizeByCategory") as? Bool ?? true
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        startInMenuBar = defaults.object(forKey: "startInMenuBar") as? Bool ?? true
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? true
        loginItemAutoRegistered = defaults.object(forKey: "loginItemAutoRegistered") as? Bool ?? false
        denoPromptSuppressed = defaults.object(forKey: "denoPromptSuppressed") as? Bool ?? false
        browserOnlySites = defaults.stringArray(forKey: "browserOnlySites") ?? []
    }

    static let mp3Arguments = ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]

    /// yt-dlp arguments for the chosen format/quality.
    var ytdlpFormatArguments: [String] {
        let custom = videoFormat.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return ["-f", custom, "--merge-output-format", videoContainer == "original" ? "mkv" : videoContainer] }
        if videoMaxHeight == -1 { return ["-f", "ba/b", "-x", "--audio-format", "m4a", "--audio-quality", "0"] }
        if videoMaxHeight == -2 { return Self.mp3Arguments }
        let h = videoMaxHeight > 0 ? "[height<=\(videoMaxHeight)]" : ""
        var expr: String
        var args: [String] = []
        switch videoContainer {
        case "mp4":
            // Prefer H.264 + AAC so the file plays everywhere (QuickTime, iOS); fall back to anything and merge into mp4.
            expr = "bv*\(h)[vcodec^=avc1]+ba[acodec^=mp4a]/bv*\(h)[ext=mp4]+ba[ext=m4a]/bv*\(h)+ba/b\(h)/b"
            args = ["--merge-output-format", "mp4", "--remux-video", "mp4"]
        case "webm":
            expr = "bv*\(h)[ext=webm]+ba[ext=webm]/bv*\(h)+ba/b\(h)/b"
            args = ["--merge-output-format", "webm"]
        case "mkv":
            expr = "bv*\(h)+ba/b\(h)/b"
            args = ["--merge-output-format", "mkv"]
        default:
            expr = "bv*\(h)+ba/b\(h)/b"
        }
        return ["-f", expr] + args
    }
}
