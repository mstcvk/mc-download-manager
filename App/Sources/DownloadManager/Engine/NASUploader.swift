import Foundation

/// NAS/ağ konumlarına dosya yüklemek için yardımcı sınıf.
/// SMB (mount_smbfs), FTP (curl), SFTP (curl + sftp://), WebDAV (curl PUT) destekler.
enum NASUploader {

    struct NASError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Dosyayı NAS'a yükler. Tamamlandığında completion çağrılır (ana iş parçacığından değil).
    static func upload(file: URL, config: NASConfig, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try performUpload(file: file, config: config)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Bağlantıyı test eder. Başarılı ise nil, başarısız ise hata döner.
    static func testConnection(_ config: NASConfig) -> (ok: Bool, error: String?) {
        switch config.protocol {
        case "smb":
            return testSMB(config)
        case "ftp":
            return testCurl(config, scheme: "ftp")
        case "sftp":
            return testCurl(config, scheme: "sftp")
        case "webdav":
            return testWebDAV(config)
        default:
            return (false, "Unknown protocol: \(config.protocol)")
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

    private static func uploadSMB(file: URL, config: NASConfig) throws -> String {
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

        let smbURL = buildSMBURL(config)
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        mount.arguments = [smbURL, mountPoint.path]
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

        // Hedef dizini oluştur (path'teki alt klasörler)
        let remotePath = config.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var destDir = mountPoint
        if !remotePath.isEmpty {
            // SMB share'ın mount noktasında path'teki alt klasörleri oluştur
            // İlk kısım share adı olarak zaten mount edildi, geri kalanı dizin
            destDir = mountPoint.appendingPathComponent(remotePath)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let dest = destDir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest.lastPathComponent
    }

    private static func buildSMBURL(_ config: NASConfig) -> String {
        var auth = ""
        if !config.user.isEmpty {
            let user = config.user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? config.user
            let pass = config.pass.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? config.pass
            auth = config.pass.isEmpty ? "\(user)@" : "\(user):\(pass)@"
        }
        let port = config.port > 0 ? ":\(config.port)" : ""
        let path = config.path.hasPrefix("/") ? config.path : "/\(config.path)"
        // mount_smbfs share yolunu bekler
        return "//\(auth)\(config.host)\(port)\(path)"
    }

    private static func testSMB(_ config: NASConfig) -> (ok: Bool, error: String?) {
        // Hızlı test: smbutil ile bağlantı kontrolü
        let smbURL = "smb://\(config.host)"
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

    // MARK: - FTP / SFTP (curl)

    private static func uploadCurl(file: URL, config: NASConfig, scheme: String) throws -> String {
        let remotePath = config.path.hasSuffix("/") ? config.path : config.path + "/"
        let port = config.effectivePort
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(file.lastPathComponent)"

        var args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S"]
        if !config.user.isEmpty {
            args += ["-u", "\(config.user):\(config.pass)"]
        }
        if scheme == "sftp" {
            args += ["--insecure"]   // NAS cihazlarında self-signed sertifika yaygın
        }
        if scheme == "ftp" {
            args += ["--ftp-create-dirs"]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "\(scheme.uppercased()) upload failed"
            throw NASError(message: "\(scheme.uppercased()) upload failed: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return file.lastPathComponent
    }

    private static func testCurl(_ config: NASConfig, scheme: String) -> (ok: Bool, error: String?) {
        let port = config.effectivePort
        let path = config.path.hasSuffix("/") ? config.path : config.path + "/"
        let url = "\(scheme)://\(config.host):\(port)\(path)"
        var args = [url, "--connect-timeout", "10", "-s", "-S", "--list-only"]
        if !config.user.isEmpty { args += ["-u", "\(config.user):\(config.pass)"] }
        if scheme == "sftp" { args += ["--insecure"] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args
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

    // MARK: - WebDAV (curl PUT)

    private static func uploadWebDAV(file: URL, config: NASConfig) throws -> String {
        let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
        let port = config.effectivePort
        let remotePath = config.path.hasSuffix("/") ? config.path : config.path + "/"
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(file.lastPathComponent)"

        var args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S"]
        if !config.user.isEmpty { args += ["-u", "\(config.user):\(config.pass)"] }
        args += ["--insecure"]   // NAS self-signed sertifika

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "WebDAV upload failed"
            throw NASError(message: "WebDAV upload failed: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return file.lastPathComponent
    }

    private static func testWebDAV(_ config: NASConfig) -> (ok: Bool, error: String?) {
        let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
        let port = config.effectivePort
        let url = "\(scheme)://\(config.host):\(port)\(config.path)"
        var args = [url, "--connect-timeout", "10", "-s", "-S", "-I"]   // HEAD request
        if !config.user.isEmpty { args += ["-u", "\(config.user):\(config.pass)"] }
        args += ["--insecure"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
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
}
