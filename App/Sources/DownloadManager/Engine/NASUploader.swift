import Foundation

/// NAS/ağ konumlarına dosya yüklemek için yardımcı sınıf.
/// SMB (mount_smbfs), FTP (curl), SFTP (curl + sftp://), WebDAV (curl PUT) destekler.
enum NASUploader {

    private static let uploadQueue = DispatchQueue(label: "dm.nas-uploader", qos: .utility)

    struct NASError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Dosyayı NAS'a yükler. Tamamlandığında completion çağrılır (ana iş parçacığından değil).
    static func upload(file: URL, config: NASConfig, completion: @escaping (Result<String, Error>) -> Void) {
        uploadQueue.async {
            do {
                let result = try performUpload(file: file, config: config)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Bağlantıyı test eder. Başarılı ise kategori klasörlerini oluşturur ve nil hata döner.
    static func testConnection(_ config: NASConfig, createCategoryFolders: Bool = true) -> (ok: Bool, error: String?) {
        let res: (ok: Bool, error: String?)
        switch config.protocol {
        case "smb":
            res = testSMB(config)
        case "ftp":
            res = testCurl(config, scheme: "ftp")
        case "sftp":
            res = testCurl(config, scheme: "sftp")
        case "webdav":
            res = testWebDAV(config)
        default:
            return (false, "Unknown protocol: \(config.protocol)")
        }
        if res.ok && createCategoryFolders {
            uploadQueue.async {
                ensureCategoryDirectories(config)
            }
        }
        return res
    }

    /// NAS hedef dizini altında kategori klasörlerini (Video, Müzik, Arşiv, Uygulama, Belge, Resim, Diğer) otomatik oluşturur.
    static func ensureCategoryDirectories(_ config: NASConfig) {
        let basePath = config.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = basePath.isEmpty ? "" : "/\(basePath)"
        let categories = FileCategory.allCases.map(\.label)

        switch config.protocol {
        case "ftp", "sftp":
            let port = config.effectivePort
            let baseEncoded = encodePath(prefix, trailingSlash: false)
            let url = "\(config.protocol)://\(config.host):\(port)\(baseEncoded)/"
            var args = [url, "--connect-timeout", "10", "-s", "-S", "--list-only"]
            if config.protocol == "sftp" { args += ["--insecure"] }
            for cat in categories {
                let target = prefix.isEmpty ? "/\(cat)" : "\(prefix)/\(cat)"
                if config.protocol == "ftp" {
                    args += ["-Q", "-MKD \(target)"]
                } else {
                    args += ["-Q", "-mkdir \(target)"]
                }
            }
            _ = try? runCurl(args: args, config: config)
        case "smb":
            let (share, subpath) = splitSMBPath(config.path)
            guard !share.isEmpty else { return }
            let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("mcdm-nas-init-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            defer {
                let umount = Process()
                umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
                umount.arguments = [mountPoint.path]
                try? umount.run(); umount.waitUntilExit()
                try? FileManager.default.removeItem(at: mountPoint)
            }
            let mount = Process()
            mount.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
            mount.arguments = ["-N", buildSMBURL(config, share: share), mountPoint.path]
            try? mount.run(); mount.waitUntilExit()
            guard mount.terminationStatus == 0 else { return }
            let rootDir = subpath.isEmpty ? mountPoint : mountPoint.appendingPathComponent(subpath)
            for cat in categories {
                try? FileManager.default.createDirectory(at: rootDir.appendingPathComponent(cat), withIntermediateDirectories: true)
            }
        case "webdav":
            let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
            let port = config.effectivePort
            for cat in categories {
                let catPath = encodePath("\(prefix)/\(cat)", trailingSlash: true)
                let url = "\(scheme)://\(config.host):\(port)\(catPath)"
                _ = try? runCurl(args: ["-X", "MKCOL", url, "--connect-timeout", "8", "-s", "--insecure"], config: config)
            }
        default:
            break
        }
    }

    // MARK: - Upload

    private static func performUpload(file: URL, config: NASConfig) throws -> String {
        switch config.protocol {
        case "smb":
            return try uploadSMB(file: file, config: config)
        case "ftp":
            return try uploadCurl(file: file, config: config, scheme: "ftp")
        case "sftp":
            return try uploadCurl(file: file, config: config, scheme: "sftp")
        case "webdav":
            return try uploadWebDAV(file: file, config: config)
        default:
            throw NASError(message: "Unsupported protocol: \(config.protocol)")
        }
    }

    // MARK: - SMB

    /// Path'i SMB paylaşım adı (ilk bileşen) ve alt klasör yolu olarak ayırır.
    private static func splitSMBPath(_ rawPath: String) -> (share: String, subpath: String) {
        let parts = rawPath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard let share = parts.first else { return ("", "") }
        let sub = parts.dropFirst().joined(separator: "/")
        return (share, sub)
    }

    private static func uploadSMB(file: URL, config: NASConfig) throws -> String {
        let (share, subpath) = splitSMBPath(config.path)
        guard !share.isEmpty else {
            throw NASError(message: "SMB share path is required (e.g. /downloads)")
        }

        // SMB: mount → copy → unmount
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("mcdm-nas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            let umount = Process()
            umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            umount.arguments = [mountPoint.path]
            umount.standardOutput = FileHandle.nullDevice
            umount.standardError = FileHandle.nullDevice
            try? umount.run(); umount.waitUntilExit()
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let smbURL = buildSMBURL(config, share: share)
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        mount.arguments = ["-N", smbURL, mountPoint.path]
        mount.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        mount.standardError = errPipe
        try mount.run()
        mount.waitUntilExit()
        guard mount.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "mount failed"
            throw NASError(message: "SMB mount failed: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Hedef dizini oluştur (paylaşım içindeki alt klasörler)
        var destDir = mountPoint
        if !subpath.isEmpty {
            destDir = mountPoint.appendingPathComponent(subpath)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let dest = destDir.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        return dest.lastPathComponent
    }

    private static func buildSMBURL(_ config: NASConfig, share: String) -> String {
        var auth = ""
        if !config.user.isEmpty {
            let user = config.user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? config.user
            let pass = config.pass.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? config.pass
            auth = config.pass.isEmpty ? "\(user)@" : "\(user):\(pass)@"
        }
        let port = config.port > 0 ? ":\(config.port)" : ""
        let encodedShare = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share
        return "//\(auth)\(config.host)\(port)/\(encodedShare)"
    }

    private static func testSMB(_ config: NASConfig) -> (ok: Bool, error: String?) {
        // Hızlı test: smbutil ile bağlantı kontrolü
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        proc.arguments = ["status", config.host]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 { return (true, nil) }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Connection failed"
            return (false, errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Yardımcılar (URL Kodlama ve Güvenli Kimlik Doğrulama)

    private static func encodePath(_ path: String, trailingSlash: Bool = true) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "[]{}")
        let parts = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
        }
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/") + (trailingSlash ? "/" : "")
    }

    private static func encodeFileName(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]{}")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// Parolayı komut satırı argümanlarında (ps aux) sızdırmamak için curl stdin config (-K -) formatı üretir.
    private static func curlAuthStdin(_ config: NASConfig) -> Data? {
        guard !config.user.isEmpty else { return nil }
        let raw = "\(config.user):\(config.pass)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return Data("user = \"\(raw)\"\n".utf8)
    }

    private static func runCurl(args: [String], config: NASConfig) throws -> (status: Int32, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var fullArgs = ["-g"] + args
        var inPipe: Pipe?
        if curlAuthStdin(config) != nil {
            fullArgs += ["-K", "-"]
            let p = Pipe()
            proc.standardInput = p
            inPipe = p
        }
        proc.arguments = fullArgs
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        if let inPipe, let authData = curlAuthStdin(config) {
            inPipe.fileHandleForWriting.write(authData)
            try? inPipe.fileHandleForWriting.close()
        }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - FTP / SFTP (curl)

    private static func uploadCurl(file: URL, config: NASConfig, scheme: String) throws -> String {
        let remotePath = encodePath(config.path, trailingSlash: true)
        let encodedName = encodeFileName(file.lastPathComponent)
        let port = config.effectivePort
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(encodedName)"

        var args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S"]
        if scheme == "sftp" {
            args += ["--insecure", "--ftp-create-dirs"]   // NAS cihazlarında self-signed/host key
        }
        if scheme == "ftp" {
            args += ["--ftp-create-dirs"]
        }

        let res = try runCurl(args: args, config: config)
        guard res.status == 0 else {
            let msg = res.stderr.isEmpty ? "\(scheme.uppercased()) upload failed" : res.stderr
            throw NASError(message: "\(scheme.uppercased()) upload failed: \(msg)")
        }
        return file.lastPathComponent
    }

    private static func testCurl(_ config: NASConfig, scheme: String) -> (ok: Bool, error: String?) {
        let port = config.effectivePort
        let path = encodePath(config.path, trailingSlash: true)
        let url = "\(scheme)://\(config.host):\(port)\(path)"
        var args = [url, "--connect-timeout", "10", "-s", "-S", "--list-only"]
        if scheme == "sftp" { args += ["--insecure"] }

        do {
            let res = try runCurl(args: args, config: config)
            if res.status == 0 { return (true, nil) }
            return (false, res.stderr.isEmpty ? "Connection failed" : res.stderr)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - WebDAV (curl PUT)

    private static func uploadWebDAV(file: URL, config: NASConfig) throws -> String {
        let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
        let port = config.effectivePort
        let remotePath = encodePath(config.path, trailingSlash: true)
        let encodedName = encodeFileName(file.lastPathComponent)
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(encodedName)"

        let args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S", "--fail", "--insecure"]
        let res = try runCurl(args: args, config: config)
        guard res.status == 0 else {
            let msg = res.stderr.isEmpty ? "WebDAV upload failed" : res.stderr
            throw NASError(message: "WebDAV upload failed: \(msg)")
        }
        return file.lastPathComponent
    }

    private static func testWebDAV(_ config: NASConfig) -> (ok: Bool, error: String?) {
        let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
        let port = config.effectivePort
        let remotePath = encodePath(config.path, trailingSlash: false)
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)"
        let args = [url, "--connect-timeout", "10", "-s", "-S", "--fail", "-I", "--insecure"]

        do {
            let res = try runCurl(args: args, config: config)
            if res.status == 0 { return (true, nil) }
            return (false, res.stderr.isEmpty ? "Connection failed" : res.stderr)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
