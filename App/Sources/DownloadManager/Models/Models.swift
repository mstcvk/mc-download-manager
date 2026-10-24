import Foundation

enum DownloadKind: String, Codable {
    case file
    case video
    case audio      // yt-dlp, extracted to MP3
}

enum DownloadState: String, Codable {
    case queued, probing, downloading, paused, completed, failed, cancelled

    var isActive: Bool { self == .probing || self == .downloading }

    var label: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .probing: return String(localized: "Connecting")
        case .downloading: return String(localized: "Downloading")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Error")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

struct SegmentInfo: Codable, Equatable {
    var start: Int64
    var end: Int64          // inclusive
    var received: Int64 = 0

    var length: Int64 { end - start + 1 }
    var isDone: Bool { received >= length }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var fileName: String
    var directory: URL
    var kind: DownloadKind = .file
    var state: DownloadState = .queued
    var totalBytes: Int64 = -1
    var receivedBytes: Int64 = 0
    var supportsRanges = false
    var segments: [SegmentInfo] = []
    var headers: [String: String] = [:]
    var cookieFile: String? = nil
    var errorMessage: String? = nil
    var createdAt = Date()
    var completedAt: Date? = nil
    var finalPath: String? = nil
    var requestedSegments: Int = 0      // 0 = ayarlardaki değer
    var sourceBrowser: String? = nil    // extension that sent it (chrome, brave, opera, edge, firefox, safari)

    // Kalıcı olmayan alanlar
    var speed: Double = 0
    var log: String = ""
    var stage: String = ""      // yt-dlp: current phase (downloading video/audio, merging…)
    var lastHTTPStatus: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, url, fileName, directory, kind, state, totalBytes, receivedBytes, supportsRanges,
             segments, headers, cookieFile, errorMessage, createdAt, completedAt, finalPath, requestedSegments, sourceBrowser
    }

    var destinationURL: URL { directory.appendingPathComponent(fileName) }
    /// Parça dosyası: ad değişse bile sabit kalsın diye id tabanlı.
    var partURL: URL { directory.appendingPathComponent(".dm-\(id.uuidString).part") }
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
    var eta: TimeInterval? {
        guard totalBytes > 0, speed > 1 else { return nil }
        return Double(totalBytes - receivedBytes) / speed
    }
}

struct DownloadFailure: LocalizedError {
    let message: String
    var local = false           // disk/file problem: a browser would not do better
    var errorDescription: String? { message }
}

struct HTTPStatusError: LocalizedError {
    let status: Int
    var errorDescription: String? { String(localized: "Server returned HTTP \(status)") }
}

// MARK: - Kategori

enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case image, music, video, apps, document, compressed, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: return String(localized: "Images")
        case .music: return String(localized: "Music")
        case .video: return String(localized: "Video")
        case .apps: return String(localized: "Apps")
        case .document: return String(localized: "Documents")
        case .compressed: return String(localized: "Archives")
        case .other: return String(localized: "Other")
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .music: return "music.note"
        case .video: return "film"
        case .apps: return "app.badge"
        case .document: return "doc.text"
        case .compressed: return "doc.zipper"
        case .other: return "doc"
        }
    }

    private static let table: [FileCategory: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "psd", "ai", "raw", "cr2", "nef", "ico"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"],
        .video: ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m3u8", "3gp"],
        .apps: ["dmg", "pkg", "app", "exe", "msi", "apk", "ipa", "deb", "rpm", "appimage", "jar", "xpi", "crx"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "epub", "mobi", "csv", "md", "pages", "numbers", "key"],
        .compressed: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img", "cab"],
    ]

    static func detect(fileName: String, kind: DownloadKind) -> FileCategory {
        if kind == .video { return .video }
        if kind == .audio { return .music }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        for (cat, exts) in table where exts.contains(ext) { return cat }
        return .other
    }
}

extension DownloadItem {
    var category: FileCategory { FileCategory.detect(fileName: fileName, kind: kind) }
    var isFinished: Bool { state == .completed }
    var referer: URL? { headers["Referer"].flatMap { URL(string: $0) } }
}
