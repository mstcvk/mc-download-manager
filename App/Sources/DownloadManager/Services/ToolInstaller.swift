import CryptoKit
import Foundation

/// Downloads the latest yt-dlp from GitHub into Application Support so the app can
/// install it when missing and keep it current (YouTube changes break old yt-dlp builds often).
final class ToolInstaller: ObservableObject {
    static let shared = ToolInstaller()

    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message: String?
    @Published var installedVersion: String?

    static let ytDlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    static let ytDlpLatestReleaseAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    static var binDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MC Download Manager/bin", isDirectory: true)
    }
    static var userYtDlpPath: String { binDirectory.appendingPathComponent("yt-dlp").path }
    static var userDenoPath: String { binDirectory.appendingPathComponent("deno").path }

    #if arch(arm64)
    private static let denoTriple = "aarch64-apple-darwin"
    #else
    private static let denoTriple = "x86_64-apple-darwin"
    #endif
    static let denoZipURL = URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(denoTriple).zip")!
    /// Approximate download size, shown in the install prompt.
    static let denoDownloadSize = "~40 MB"

    /// `yt-dlp --version` for the given executable (cached per path).
    private var versionCache: [String: String] = [:]
    func version(of path: String) -> String? {
        if let v = versionCache[path] { return v }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        p.environment = VideoDownloader.environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // deno prints three lines (deno, v8, typescript); keep the first.
        let v = String(data: data, encoding: .utf8)?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        if let v, !v.isEmpty { versionCache[path] = v }
        return v
    }

    @Published var denoVersion: String?

    func refreshVersion(custom: String) {
        DispatchQueue.global().async { [weak self] in
            let v = VideoDownloader.locateYtDlp(custom: custom).flatMap { self?.version(of: $0) }
            let d = VideoDownloader.locateDeno().flatMap { self?.version(of: $0) }
            DispatchQueue.main.async { self?.installedVersion = v; self?.denoVersion = d }
        }
    }

    /// Reports the yt-dlp version in use and, when GitHub has a newer release, that release's version.
    /// `newer` is nil when the copy in use is current or the lookup failed; `reachable` tells the two apart.
    func checkForNewerYtDlp(custom: String,
                            completion: @escaping (_ installed: String?, _ newer: String?, _ reachable: Bool) -> Void) {
        DispatchQueue.global().async { [weak self] in
            let installed = VideoDownloader.locateYtDlp(custom: custom).flatMap { self?.version(of: $0) }
            var req = URLRequest(url: Self.ytDlpLatestReleaseAPI, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                var latest: String?
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    latest = obj["tag_name"] as? String
                }
                var newer: String?
                if let latest, installed.map({ UpdateChecker.isNewer(latest, than: $0) }) ?? true { newer = latest }
                DispatchQueue.main.async { completion(installed, newer, latest != nil) }
            }.resume()
        }
    }

    /// Downloads yt-dlp_macos, verifies it runs, and installs it to Application Support.
    func installOrUpdateYtDlp(completion: @escaping (Result<String, Error>) -> Void) {
        guard !busy else {
            completion(.failure(DownloadFailure(message: String(localized: "Another tool install is in progress."))))
            return
        }
        busy = true
        progress = 0
        message = String(localized: "Downloading yt-dlp…")
        let dl = SegmentedDownloader(configuration: .init(
            url: Self.ytDlpURL,
            headers: ["User-Agent": DownloadStore.defaultUserAgent],
            partURL: Self.binDirectory.appendingPathComponent(".yt-dlp.download"),
            segmentCount: 4))
        var total: Int64 = -1
        dl.onProbe = { p in total = p.totalBytes }
        dl.onProgress = { [weak self] received, _ in
            DispatchQueue.main.async { if total > 0 { self?.progress = Double(received) / Double(total) } }
        }
        dl.onFinish = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let e):
                    self.finish(.failure(e), completion)
                case .success:
                    self.message = String(localized: "Verifying…")
                    DispatchQueue.global().async {
                        let r = self.installDownloaded()
                        DispatchQueue.main.async { self.finish(r, completion) }
                    }
                }
            }
        }
        try? FileManager.default.createDirectory(at: Self.binDirectory, withIntermediateDirectories: true)
        dl.start()
    }

    private func installDownloaded() -> Result<String, Error> {
        let fm = FileManager.default
        let tmp = Self.binDirectory.appendingPathComponent(".yt-dlp.download")
        let dest = Self.binDirectory.appendingPathComponent("yt-dlp")
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            // Remove quarantine so Gatekeeper lets us execute it.
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-d", "com.apple.quarantine", tmp.path]
            x.standardError = FileHandle.nullDevice
            try? x.run(); x.waitUntilExit()
            versionCache[tmp.path] = nil
            guard let v = version(of: tmp.path), !v.isEmpty else {
                try? fm.removeItem(at: tmp)
                throw DownloadFailure(message: String(localized: "The downloaded yt-dlp binary could not be executed."))
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            versionCache[dest.path] = v
            return .success(v)
        } catch {
            try? fm.removeItem(at: tmp)
            return .failure(error)
        }
    }

    // MARK: - deno (JavaScript runtime yt-dlp needs for YouTube's signature/n challenges)

    /// Downloads the latest deno release zip for this architecture, checks it against the
    /// published SHA-256, unpacks it and installs it to Application Support.
    func installDeno(completion: @escaping (Result<String, Error>) -> Void) {
        guard !busy else {
            completion(.failure(DownloadFailure(message: String(localized: "Another tool install is in progress."))))
            return
        }
        busy = true
        progress = 0
        message = String(localized: "Downloading deno…")
        try? FileManager.default.createDirectory(at: Self.binDirectory, withIntermediateDirectories: true)
        let zip = Self.binDirectory.appendingPathComponent(".deno.zip")
        let dl = SegmentedDownloader(configuration: .init(
            url: Self.denoZipURL,
            headers: ["User-Agent": DownloadStore.defaultUserAgent],
            partURL: zip,
            segmentCount: 4))
        var total: Int64 = -1
        dl.onProbe = { p in total = p.totalBytes }
        dl.onProgress = { [weak self] received, _ in
            DispatchQueue.main.async { if total > 0 { self?.progress = Double(received) / Double(total) } }
        }
        dl.onFinish = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let e):
                    try? FileManager.default.removeItem(at: zip)
                    self.finishDeno(.failure(e), completion)
                case .success:
                    self.message = String(localized: "Verifying…")
                    DispatchQueue.global().async {
                        let r = self.installDownloadedDeno(zip: zip)
                        DispatchQueue.main.async { self.finishDeno(r, completion) }
                    }
                }
            }
        }
        dl.start()
    }

    private func installDownloadedDeno(zip: URL) -> Result<String, Error> {
        let fm = FileManager.default
        let staging = Self.binDirectory.appendingPathComponent(".deno-unpack", isDirectory: true)
        let dest = URL(fileURLWithPath: Self.userDenoPath)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: staging)
        }
        do {
            try verifyChecksum(of: zip, against: URL(string: Self.denoZipURL.absoluteString + ".sha256sum")!)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, staging.path]
            unzip.standardError = FileHandle.nullDevice
            try unzip.run(); unzip.waitUntilExit()
            let bin = staging.appendingPathComponent("deno")
            guard unzip.terminationStatus == 0, fm.fileExists(atPath: bin.path) else {
                throw DownloadFailure(message: String(localized: "The deno archive could not be unpacked."))
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            versionCache[bin.path] = nil
            guard let v = version(of: bin.path), v.hasPrefix("deno ") else {
                throw DownloadFailure(message: String(localized: "The downloaded deno binary could not be executed."))
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: bin, to: dest)
            versionCache[dest.path] = v
            return .success(v)
        } catch {
            return .failure(error)
        }
    }

    /// Compares the file's SHA-256 with the first field of a `<hash>  <name>` checksum file.
    private func verifyChecksum(of file: URL, against sumURL: URL) throws {
        var req = URLRequest(url: sumURL, timeoutInterval: 30)
        req.setValue(DownloadStore.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { body = d }
            sem.signal()
        }.resume()
        sem.wait()
        guard let expected = body.flatMap({ String(data: $0, encoding: .utf8) })?
                .split(whereSeparator: \.isWhitespace).first?.lowercased(),
              expected.count == 64 else {
            throw DownloadFailure(message: String(localized: "Could not fetch the checksum for verification."))
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw DownloadFailure(message: String(localized: "Checksum mismatch; the download was discarded."))
        }
    }

    private func finishDeno(_ r: Result<String, Error>, _ completion: (Result<String, Error>) -> Void) {
        busy = false
        progress = 0
        switch r {
        case .success(let v):
            denoVersion = v
            message = String(localized: "\(v) installed.")
        case .failure(let e):
            message = String(localized: "Install failed: \(e.localizedDescription)")
        }
        completion(r)
    }

    private func finish(_ r: Result<String, Error>, _ completion: (Result<String, Error>) -> Void) {
        busy = false
        progress = 0
        switch r {
        case .success(let v):
            installedVersion = v
            message = String(localized: "yt-dlp \(v) installed.")
        case .failure(let e):
            message = String(localized: "Install failed: \(e.localizedDescription)")
        }
        completion(r)
    }
}
