import Foundation
import Darwin

/// BitTorrent motoru: tek bir yerel aria2c süreci JSON-RPC (127.0.0.1, gizli anahtarlı) ile sürülür.
/// Uygulama içine gömülü ikili (Contents/Helpers/aria2c) varsa onu, yoksa Homebrew'daki aria2c'yi kullanır.
/// Süreç uygulama kapanınca kendiliğinden biter (--stop-with-process).
final class TorrentEngine {
    static let shared = TorrentEngine()

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct TorrentFile {
        var index: Int
        var path: String
        var length: Int64
        var completed: Int64
        var selected: Bool
    }

    struct Status {
        var gid: String
        var status: String              // active, waiting, paused, error, complete, removed
        var totalLength: Int64
        var completedLength: Int64
        var downloadSpeed: Double
        var connections: Int
        var numSeeders: Int
        var followedBy: [String]
        var errorMessage: String?
        var infoHash: String?
        var dir: String?
        var name: String?               // bittorrent.info.name (nil until metadata arrives)
        var files: [TorrentFile]

        /// Magnet links first download a small metadata "torrent" named [METADATA]<hash>.
        var isMetadata: Bool { name == nil || (name ?? "").hasPrefix("[METADATA]") }
    }

    private var process: Process?
    private var port = 0
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "mcdm.torrent.engine")
    private var starting = false
    private var startWaiters: [(Result<Void, Error>) -> Void] = []
    private var stderrTail = ""
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.connectionProxyDictionary = [:]   // never route localhost RPC through a system proxy
        return URLSession(configuration: c)
    }()

    var isRunning: Bool { queue.sync { process?.isRunning ?? false } }

    // MARK: - aria2c bulma

    static func locateAria2c() -> String? {
        let candidates = [
            VideoDownloader.helpersDirectory.appendingPathComponent("aria2c").path,
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/aria2c"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: - Süreç

    /// Starts aria2c if it is not running and calls back once its RPC answers.
    func ensureRunning(downloadDirectory: String, downloadLimit: String = "0", completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if let p = self.process, p.isRunning { completion(.success(())); return }
            self.startWaiters.append(completion)
            guard !self.starting else { return }
            self.starting = true
            self.launch(downloadDirectory: downloadDirectory, downloadLimit: downloadLimit)
        }
    }

    private func launch(downloadDirectory: String, downloadLimit: String) {
        guard let exe = Self.locateAria2c() else {
            finishStart(.failure(EngineError(message: String(localized: "aria2c not found. Install it with Homebrew: brew install aria2"))))
            return
        }
        port = Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--dir=\(downloadDirectory)",
            "--continue=true",
            "--seed-time=0",                    // bitince paylaşım (seed) yok
            "--bt-save-metadata=true",          // magnet meta verisi <infohash>.torrent olarak saklanır (devam için)
            "--pause-metadata=true",            // magnet meta verisi gelince dur: dosya seçimi için
            "--max-overall-download-limit=\(downloadLimit)",
            "--bt-remove-unselected-file=false",
            "--max-concurrent-downloads=64",    // sırayı DownloadStore yönetir
            "--file-allocation=none",
            "--auto-save-interval=10",
            "--console-log-level=warn",
            "--summary-interval=0",
            "--quiet=false",
        ]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let self, let s = String(data: d, encoding: .utf8) else { return }
            self.queue.async { self.stderrTail = String((self.stderrTail + s).suffix(2000)) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.process === p { self.process = nil } }
        }
        do {
            try p.run()
        } catch {
            finishStart(.failure(error))
            return
        }
        process = p
        waitForRPC(deadline: Date().addingTimeInterval(8))
    }

    private func waitForRPC(deadline: Date) {
        rawCall("aria2.getVersion", [tokenParam]) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success:
                    self.finishStart(.success(()))
                case .failure:
                    if Date() > deadline || !(self.process?.isRunning ?? false) {
                        let tail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.process?.terminate()
                        self.process = nil
                        self.finishStart(.failure(EngineError(message: tail.isEmpty ? String(localized: "aria2c did not start") : "aria2c: \(tail)")))
                    } else {
                        self.queue.asyncAfter(deadline: .now() + 0.15) { self.waitForRPC(deadline: deadline) }
                    }
                }
            }
        }
    }

    /// queue üzerinde çağrılır.
    private func finishStart(_ result: Result<Void, Error>) {
        starting = false
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0(result) }
    }

    func shutdown() {
        queue.sync {
            guard let p = process, p.isRunning else { return }
            p.terminate()          // SIGTERM: aria2 writes its .aria2 control files before exiting
            process = nil
        }
    }

    // MARK: - İşlemler

    func addMagnet(_ uri: String, options: [String: String], completion: @escaping (Result<String, Error>) -> Void) {
        call("aria2.addUri", [[uri], options]) { completion($0.flatMap(Self.gid)) }
    }

    func addTorrent(fileAt path: String, options: [String: String], completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = FileManager.default.contents(atPath: path) else {
            completion(.failure(EngineError(message: String(localized: "Cannot read the torrent file."))))
            return
        }
        call("aria2.addTorrent", [data.base64EncodedString(), [String](), options]) { completion($0.flatMap(Self.gid)) }
    }

    func pause(_ gid: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        call("aria2.forcePause", [gid]) { r in completion?(r.map { _ in () }) }
    }

    func changeOption(_ gid: String, _ options: [String: String], completion: @escaping (Result<Void, Error>) -> Void) {
        call("aria2.changeOption", [gid, options]) { completion($0.map { _ in () }) }
    }

    /// Changes the overall torrent download limit of the running aria2 ("0" = unlimited). No-op when it is not running.
    func setDownloadLimit(_ limit: String) {
        guard isRunning else { return }
        call("aria2.changeGlobalOption", [["max-overall-download-limit": limit]]) { _ in }
    }

    func unpause(_ gid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("aria2.unpause", [gid]) { completion($0.map { _ in () }) }
    }

    /// Removes the download from aria2 and forgets its result (files on disk stay).
    func remove(_ gid: String) {
        call("aria2.forceRemove", [gid]) { [weak self] _ in
            self?.call("aria2.removeDownloadResult", [gid]) { _ in }
        }
    }

    func forget(_ gid: String) {
        call("aria2.removeDownloadResult", [gid]) { _ in }
    }

    private static let statusKeys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "connections",
                                     "numSeeders", "followedBy", "errorCode", "errorMessage", "infoHash", "dir",
                                     "bittorrent", "files"]

    /// One RPC round trip for all gids. Missing gids (aria2 restarted, result removed) are absent from the result.
    func statuses(_ gids: [String], completion: @escaping (Result<[String: Status], Error>) -> Void) {
        guard !gids.isEmpty else { completion(.success([:])); return }
        let calls: [[String: Any]] = gids.map { ["methodName": "aria2.tellStatus", "params": [tokenParam, $0, Self.statusKeys]] }
        rawCall("system.multicall", [calls]) { result in
            completion(result.map { any in
                var out: [String: Status] = [:]
                for entry in (any as? [Any]) ?? [] {
                    // success → [statusDict]; failure → {code, message}
                    guard let dict = (entry as? [Any])?.first as? [String: Any], let s = Self.parseStatus(dict) else { continue }
                    out[s.gid] = s
                }
                return out
            })
        }
    }

    // MARK: - JSON-RPC

    private var tokenParam: String { "token:\(secret)" }

    private func call(_ method: String, _ params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        rawCall(method, [tokenParam] + params, completion: completion)
    }

    private func rawCall(_ method: String, _ params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let port = self.port
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/jsonrpc") else {
            completion(.failure(EngineError(message: String(localized: "aria2c is not running"))))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error)); return
        }
        session.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(EngineError(message: "aria2c: invalid RPC response"))); return
            }
            if let e = obj["error"] as? [String: Any] {
                completion(.failure(EngineError(message: "aria2c: \(e["message"] as? String ?? "error")"))); return
            }
            completion(.success(obj["result"] ?? NSNull()))
        }.resume()
    }

    private static func gid(_ any: Any) -> Result<String, Error> {
        if let g = any as? String { return .success(g) }
        return .failure(EngineError(message: "aria2c: no gid"))
    }

    private static func parseStatus(_ d: [String: Any]) -> Status? {
        guard let gid = d["gid"] as? String else { return nil }
        func i64(_ k: String) -> Int64 { Int64(d[k] as? String ?? "") ?? 0 }
        let bt = d["bittorrent"] as? [String: Any]
        let name = (bt?["info"] as? [String: Any])?["name"] as? String
        let files: [TorrentFile] = ((d["files"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let idx = Int(f["index"] as? String ?? "") else { return nil }
            return TorrentFile(index: idx,
                               path: f["path"] as? String ?? "",
                               length: Int64(f["length"] as? String ?? "") ?? 0,
                               completed: Int64(f["completedLength"] as? String ?? "") ?? 0,
                               selected: (f["selected"] as? String) == "true")
        }
        let errCode = d["errorCode"] as? String
        let errMsg = d["errorMessage"] as? String
        return Status(gid: gid,
                      status: d["status"] as? String ?? "",
                      totalLength: i64("totalLength"),
                      completedLength: i64("completedLength"),
                      downloadSpeed: Double(d["downloadSpeed"] as? String ?? "") ?? 0,
                      connections: Int(d["connections"] as? String ?? "") ?? 0,
                      numSeeders: Int(d["numSeeders"] as? String ?? "") ?? 0,
                      followedBy: d["followedBy"] as? [String] ?? [],
                      errorMessage: (errCode == nil || errCode == "0") ? nil : (errMsg?.isEmpty == false ? errMsg : "aria2c error \(errCode!)"),
                      infoHash: d["infoHash"] as? String,
                      dir: d["dir"] as? String,
                      name: name,
                      files: files)
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 16800 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { return 16800 }
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return 16800 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

// MARK: - Magnet / .torrent yardımcıları

enum TorrentInput {
    /// magnet:?xt=urn:btih:... or a local .torrent file.
    static func isTorrent(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "magnet" { return true }
        return url.isFileURL && url.pathExtension.lowercased() == "torrent"
    }

    /// Accepts "magnet:…", "file:///…/x.torrent" and "/…/x.torrent".
    static func url(from text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("magnet:"), let u = URL(string: s) { return u }
        if s.hasPrefix("/"), s.lowercased().hasSuffix(".torrent") { return URL(fileURLWithPath: s) }
        if let u = URL(string: s), u.isFileURL, u.pathExtension.lowercased() == "torrent" { return u }
        return nil
    }

    /// Name shown before metadata arrives: magnet "dn" or the .torrent file name.
    static func displayName(for url: URL) -> String {
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        let items = URLComponents(string: url.absoluteString)?.queryItems ?? []
        if let dn = items.first(where: { $0.name == "dn" })?.value, !dn.isEmpty { return dn }
        if let xt = items.first(where: { $0.name == "xt" })?.value, let h = xt.split(separator: ":").last {
            return "Torrent " + String(h.prefix(12))
        }
        return "Torrent"
    }
}
