import Foundation

/// NAS/ağ konumlarına dosya yüklemek ve yerel/uzak eşitleme yapmak için yardımcı sınıf.
/// SMB (mount_smbfs), FTP (curl), SFTP (curl + sftp://), WebDAV (curl PUT) destekler.
enum NASUploader {

    private static let uploadQueue = DispatchQueue(label: "dm.nas-uploader", qos: .utility)

    private static var syncedStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MC Download Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nas_synced_files.json")
    }

    private static func loadSyncedSet() -> Set<String> {
        guard let data = try? Data(contentsOf: syncedStoreURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private static func saveSyncedSet(_ set: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(set).sorted()) else { return }
        try? data.write(to: syncedStoreURL, options: .atomic)
    }

    static func markFileSynced(remoteDir: String, fileName: String) {
        let key = "\(normalizeNFC(remoteDir))/\(normalizeNFC(fileName))"
        var set = loadSyncedSet()
        if set.insert(key).inserted {
            saveSyncedSet(set)
        }
    }

    enum UploadOutcome {
        case uploaded(String)
        case skippedExisting(String)
    }

    struct NASError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Dosyayı NAS'a yükler (öncesinde NAS'ta aynı isim ve boyutta dosya olup olmadığını kontrol eder;
    /// hedef klasör yoksa yalnızca o klasörü oluşturur, varsa yeniden oluşturmaz).
    static func upload(file: URL, config: NASConfig, deleteLocalAfterUpload: Bool = false, completion: @escaping (Result<UploadOutcome, Error>) -> Void) {
        uploadQueue.async {
            do {
                let cleanedURL = stripBracketIDIfNeeded(at: file)
                let outcome = try performUpload(file: cleanedURL, config: config)
                markFileSynced(remoteDir: config.path, fileName: cleanedURL.lastPathComponent)
                if deleteLocalAfterUpload {
                    try? FileManager.default.trashItem(at: cleanedURL, resultingItemURL: nil)
                }
                completion(.success(outcome))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Bilgisayardaki indirme klasörünü tarar, NAS sunucusundaki dosyalarla karşılaştırır ve
    /// yalnızca NAS'ta bulunmayan (ve daha önce NAS'a yüklenip kullanıcı tarafından silinmemiş) tamamlanmış dosyaları NAS'a yükler.
    /// Yalnızca içinde dosya bulunan kategori klasörlerini (yoksa) oluşturur; boş kategoriler için klasör açmaz.
    static func syncLocalFiles(
        localRoot: URL,
        baseConfig: NASConfig,
        organizeByCategory: Bool,
        deleteLocalAfterUpload: Bool = false,
        respectPreviouslySynced: Bool = true,
        onStatus: @escaping (String) -> Void,
        onFileStart: ((URL, Int, Int) -> Void)? = nil,
        onFileOutcome: ((URL, Result<UploadOutcome, Error>, Int, Int) -> Void)? = nil,
        completion: @escaping (_ uploaded: Int, _ skipped: Int, _ failed: Int) -> Void
    ) {
        uploadQueue.async {
            let candidates = collectCompletedLocalFiles(in: localRoot, organizeByCategory: organizeByCategory)
            guard !candidates.isEmpty else {
                completion(0, 0, 0)
                return
            }

            let totalCount = candidates.count
            var currentIndex = 0
            var syncedHistory = loadSyncedSet()

            // Hedef NAS klasörüne göre grupla (yalnızca dosyası olan klasörler işlenir)
            var grouped: [String: [URL]] = [:]
            let baseClean = normalizeNFC(baseConfig.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for item in candidates {
                let targetPath: String
                if organizeByCategory, let cat = item.categoryLabel {
                    let catNFC = normalizeNFC(cat)
                    targetPath = baseClean.isEmpty ? "/\(catNFC)" : "/\(baseClean)/\(catNFC)"
                } else {
                    targetPath = baseClean.isEmpty ? "/" : "/\(baseClean)"
                }
                grouped[targetPath, default: []].append(item.url)
            }

            var uploadedCount = 0
            var skippedCount = 0
            var failedCount = 0

            for (remoteDirPath, files) in grouped.sorted(by: { $0.key < $1.key }) {
                guard !files.isEmpty else { continue }
                var dirConfig = baseConfig
                dirConfig.path = remoteDirPath

                let listing = listRemoteDirectory(dirConfig)
                var dirExists = listing.exists
                var existingFiles = listing.files

                for fileURL in files {
                    currentIndex += 1
                    let idx = currentIndex
                    let fileNameNFC = normalizeNFC(fileURL.lastPathComponent)
                    let historyKey = "\(normalizeNFC(remoteDirPath))/\(fileNameNFC)"

                    // Kullanıcı daha önce NAS'a yüklenen bir dosyayı NAS'tan sildiyse otomatik eşitlemede tekrar yükleme
                    if respectPreviouslySynced && syncedHistory.contains(historyKey) && !existingFiles.contains(fileNameNFC) {
                        skippedCount += 1
                        onFileOutcome?(fileURL, .success(.skippedExisting(fileNameNFC)), idx, totalCount)
                        continue
                    }

                    if dirExists && existingFiles.contains(fileNameNFC) {
                        let localSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64 ?? 0
                        if let remoteSize = remoteFileSize(fileName: fileNameNFC, config: dirConfig) {
                            if remoteSize == localSize && localSize > 0 {
                                syncedHistory.insert(historyKey)
                                if deleteLocalAfterUpload {
                                    try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                                }
                                skippedCount += 1
                                onFileOutcome?(fileURL, .success(.skippedExisting(fileNameNFC)), idx, totalCount)
                                continue
                            }
                        } else {
                            syncedHistory.insert(historyKey)
                            if deleteLocalAfterUpload {
                                try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                            }
                            skippedCount += 1
                            onFileOutcome?(fileURL, .success(.skippedExisting(fileNameNFC)), idx, totalCount)
                            continue
                        }
                    }

                    onFileStart?(fileURL, idx, totalCount)
                    onStatus("\(fileNameNFC) (\(idx)/\(totalCount))")
                    do {
                        let uploadedName = try performUploadInternal(file: fileURL, config: dirConfig, directoryAlreadyExists: dirExists)
                        dirExists = true
                        existingFiles.insert(fileNameNFC)
                        syncedHistory.insert(historyKey)
                        saveSyncedSet(syncedHistory)
                        if deleteLocalAfterUpload {
                            try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                        }
                        uploadedCount += 1
                        onFileOutcome?(fileURL, .success(.uploaded(uploadedName)), idx, totalCount)
                    } catch {
                        failedCount += 1
                        onFileOutcome?(fileURL, .failure(error), idx, totalCount)
                    }
                }
            }

            saveSyncedSet(syncedHistory)
            completion(uploadedCount, skippedCount, failedCount)
        }
    }

    /// Bağlantıyı test eder. Hiçbir kategori klasörü oluşturmaz; yalnızca hedef dizine erişimi doğrular.
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

    // MARK: - Yerel Dosya Tarama

    static func collectCompletedLocalFiles(
        in root: URL,
        organizeByCategory: Bool
    ) -> [(url: URL, categoryLabel: String?)] {
        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let knownCategories = Set(FileCategory.allCases.map { normalizeNFC($0.label) })
        var results: [(url: URL, categoryLabel: String?)] = []

        for entry in topEntries {
            let nameNFC = normalizeNFC(entry.lastPathComponent)
            if nameNFC == "Browser Plugins" { continue }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard knownCategories.contains(nameNFC),
                      let subFiles = try? fm.contentsOfDirectory(
                          at: entry,
                          includingPropertiesForKeys: [.isRegularFileKey],
                          options: [.skipsHiddenFiles]
                      ) else { continue }
                for sub in subFiles {
                    let isReg = (try? sub.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    if isReg && isCompletedDownloadFile(sub.lastPathComponent) {
                        let cleaned = stripBracketIDIfNeeded(at: sub)
                        results.append((cleaned, nameNFC))
                    }
                }
            } else {
                let isReg = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isReg && isCompletedDownloadFile(nameNFC) {
                    let cleaned = stripBracketIDIfNeeded(at: entry)
                    let cat = organizeByCategory ? normalizeNFC(FileCategory.detect(fileName: cleaned.lastPathComponent, kind: .file).label) : nil
                    results.append((cleaned, cat))
                }
            }
        }
        return results
    }

    /// Dosya adının sonundaki yt-dlp video kimliğini (örn. "Kal Benim İçin [RRDMZWFHQIM].mp4" -> "Kal Benim İçin.mp4") temizler.
    static func stripBracketID(_ fileName: String) -> String {
        let normalized = normalizeNFC(fileName)
        guard let range = normalized.range(
            of: "\\s*\\[[A-Za-z0-9_-]{6,20}\\](?=\\.[A-Za-z0-9]+$)",
            options: .regularExpression
        ) else {
            return normalized
        }
        var cleaned = normalized
        cleaned.removeSubrange(range)
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(".") ? normalized : trimmed
    }

    /// Yerel dosyada "[videoId]" eki varsa disk üzerinde temiz isme yeniden adlandırır ve yeni URL'yi döner.
    static func stripBracketIDIfNeeded(at fileURL: URL) -> URL {
        let originalName = fileURL.lastPathComponent
        let cleanedName = stripBracketID(originalName)
        guard cleanedName != normalizeNFC(originalName) else { return fileURL }
        let targetURL = fileURL.deletingLastPathComponent().appendingPathComponent(cleanedName)
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            if (try? FileManager.default.moveItem(at: fileURL, to: targetURL)) != nil {
                return targetURL
            }
        }
        return fileURL
    }

    /// Geçici, yarım kalmış (.part, .ytdl, .temp) veya yt-dlp'nin henüz birleştirmediği (.f137.mp4 vb.) dosyaları eler.
    private static func isCompletedDownloadFile(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasPrefix(".") { return false }
        let ignoredSuffixes = [".part", ".ytdl", ".temp", ".tmp", ".crdownload", ".download"]
        for suffix in ignoredSuffixes where lower.hasSuffix(suffix) { return false }
        // yt-dlp ara akış dosyaları: örn. "Video [id].f137.mp4" veya "Video [id].f251.webm"
        if fileName.range(of: "\\.f[0-9]+[-a-z0-9]*\\.[a-z0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        return true
    }

    // MARK: - Tekil Yükleme ve Uzak Kontrol

    private static func performUpload(file: URL, config: NASConfig) throws -> UploadOutcome {
        let fileNameNFC = normalizeNFC(file.lastPathComponent)
        let listing = listRemoteDirectory(config)
        if listing.exists && listing.files.contains(fileNameNFC) {
            let localSize = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
            if let remoteSize = remoteFileSize(fileName: fileNameNFC, config: config) {
                if remoteSize == localSize && localSize > 0 {
                    return .skippedExisting(fileNameNFC)
                }
            } else {
                return .skippedExisting(fileNameNFC)
            }
        }
        let uploadedName = try performUploadInternal(file: file, config: config, directoryAlreadyExists: listing.exists)
        return .uploaded(uploadedName)
    }

    private static func performUploadInternal(file: URL, config: NASConfig, directoryAlreadyExists: Bool) throws -> String {
        switch config.protocol {
        case "smb":
            return try uploadSMB(file: file, config: config)
        case "ftp":
            return try uploadCurl(file: file, config: config, scheme: "ftp", createDirs: !directoryAlreadyExists)
        case "sftp":
            return try uploadCurl(file: file, config: config, scheme: "sftp", createDirs: !directoryAlreadyExists)
        case "webdav":
            return try uploadWebDAV(file: file, config: config, createDirs: !directoryAlreadyExists)
        default:
            throw NASError(message: "Unsupported protocol: \(config.protocol)")
        }
    }

    /// Uzak klasörün var olup olmadığını ve içindeki mevcut dosya adlarını (NFC normalize edilmiş olarak) döner.
    private static func listRemoteDirectory(_ config: NASConfig) -> (exists: Bool, files: Set<String>) {
        switch config.protocol {
        case "ftp", "sftp":
            let port = config.effectivePort
            let remotePath = encodePath(config.path, trailingSlash: true)
            let url = "\(config.protocol)://\(config.host):\(port)\(remotePath)"
            var args = [url, "--connect-timeout", "10", "-s", "-S", "--list-only"]
            if config.protocol == "sftp" { args += ["--insecure"] }
            guard let res = try? runCurl(args: args, config: config, captureStdout: true), res.status == 0 else {
                return (false, [])
            }
            var names = Set<String>()
            for line in res.stdout.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, raw != ".", raw != ".." else { continue }
                let base = (raw as NSString).lastPathComponent
                if !base.isEmpty, base != ".", base != ".." {
                    names.insert(normalizeNFC(base))
                }
            }
            return (true, names)
        case "webdav":
            let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
            let port = config.effectivePort
            let remotePath = encodePath(config.path, trailingSlash: true)
            let url = "\(scheme)://\(config.host):\(port)\(remotePath)"
            let args = [url, "--connect-timeout", "10", "-s", "-S", "--fail", "-I", "--insecure"]
            let ok = (try? runCurl(args: args, config: config))?.status == 0
            return (ok, [])
        default:
            return (false, [])
        }
    }

    /// Uzak dosyanın bayt cinsinden boyutunu sorgular (bilinmiyorsa veya desteklenmiyorsa nil döner).
    private static func remoteFileSize(fileName: String, config: NASConfig) -> Int64? {
        switch config.protocol {
        case "ftp", "sftp", "webdav":
            let port = config.effectivePort
            let remotePath = encodePath(config.path, trailingSlash: true)
            let encodedName = encodeFileName(fileName)
            let scheme: String
            if config.protocol == "webdav" {
                scheme = config.port == 443 || config.port == 0 ? "https" : "http"
            } else {
                scheme = config.protocol
            }
            let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(encodedName)"
            var args = [url, "--connect-timeout", "8", "-s", "-S", "-I"]
            if config.protocol != "ftp" { args += ["--insecure"] }
            guard let res = try? runCurl(args: args, config: config, captureStdout: true), res.status == 0 else {
                return nil
            }
            for line in res.stdout.split(whereSeparator: \.isNewline) {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let valStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let size = Int64(valStr) { return size }
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - SMB

    /// Path'i SMB paylaşım adı (ilk bileşen) ve alt klasör yolu olarak ayırır.
    private static func splitSMBPath(_ rawPath: String) -> (share: String, subpath: String) {
        let normalized = normalizeNFC(rawPath)
        let parts = normalized.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard let share = parts.first else { return ("", "") }
        let sub = parts.dropFirst().joined(separator: "/")
        return (share, sub)
    }

    private static func uploadSMB(file: URL, config: NASConfig) throws -> String {
        let (share, subpath) = splitSMBPath(config.path)
        guard !share.isEmpty else {
            throw NASError(message: "SMB share path is required (e.g. /downloads)")
        }

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

        // Hedef dizin yoksa oluştur, varsa yeniden oluşturma
        var destDir = mountPoint
        if !subpath.isEmpty {
            destDir = mountPoint.appendingPathComponent(subpath)
            if !FileManager.default.fileExists(atPath: destDir.path) {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
        }

        let fileNameNFC = normalizeNFC(file.lastPathComponent)
        let dest = destDir.appendingPathComponent(fileNameNFC)
        if FileManager.default.fileExists(atPath: dest.path) {
            let localSize = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
            let remoteSize = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64 ?? -1
            if localSize > 0 && localSize == remoteSize {
                return fileNameNFC
            }
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        return fileNameNFC
    }

    private static func buildSMBURL(_ config: NASConfig, share: String) -> String {
        var auth = ""
        if !config.user.isEmpty {
            let user = config.user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? config.user
            let pass = config.pass.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? config.pass
            auth = config.pass.isEmpty ? "\(user)@" : "\(user):\(pass)@"
        }
        let port = config.port > 0 ? ":\(config.port)" : ""
        let encodedShare = normalizeNFC(share).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share
        return "//\(auth)\(config.host)\(port)/\(encodedShare)"
    }

    private static func testSMB(_ config: NASConfig) -> (ok: Bool, error: String?) {
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

    // MARK: - Yardımcılar (NFC Normalizasyonu, URL Kodlama ve Güvenli Kimlik Doğrulama)

    /// macOS APFS dosya sistemindeki NFD (ayrık) Türkçe karakterleri standart NFC (birleşik) UTF-8 formuna dönüştürür.
    /// Böylece Linux/QNAP/Synology NAS üzerinde "Müzik", "Arşiv", "Diğer" gibi klasör ve dosyaların çift oluşması önlenir.
    static func normalizeNFC(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private static func encodePath(_ path: String, trailingSlash: Bool = true) -> String {
        let normalized = normalizeNFC(path)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "[]{}")
        let parts = normalized.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
        }
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/") + (trailingSlash ? "/" : "")
    }

    private static func encodeFileName(_ name: String) -> String {
        let normalized = normalizeNFC(name)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]{}")
        return normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized
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

    private static func runCurl(
        args: [String],
        config: NASConfig,
        captureStdout: Bool = false
    ) throws -> (status: Int32, stdout: String, stderr: String) {
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
        let outPipe = captureStdout ? Pipe() : nil
        if let outPipe {
            proc.standardOutput = outPipe
        } else {
            proc.standardOutput = FileHandle.nullDevice
        }
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        if let inPipe, let authData = curlAuthStdin(config) {
            inPipe.fileHandleForWriting.write(authData)
            try? inPipe.fileHandleForWriting.close()
        }
        let outData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (
            proc.terminationStatus,
            outStr.trimmingCharacters(in: .whitespacesAndNewlines),
            errStr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - FTP / SFTP (curl)

    private static func uploadCurl(file: URL, config: NASConfig, scheme: String, createDirs: Bool) throws -> String {
        let remotePath = encodePath(config.path, trailingSlash: true)
        let fileNameNFC = normalizeNFC(file.lastPathComponent)
        let encodedName = encodeFileName(fileNameNFC)
        let port = config.effectivePort
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(encodedName)"

        var args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S"]
        if scheme == "sftp" {
            args += ["--insecure"]
        }
        if createDirs {
            args += ["--ftp-create-dirs"]
        }

        let res = try runCurl(args: args, config: config)
        guard res.status == 0 else {
            let msg = res.stderr.isEmpty ? "\(scheme.uppercased()) upload failed" : res.stderr
            throw NASError(message: "\(scheme.uppercased()) upload failed: \(msg)")
        }
        return fileNameNFC
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

    private static func uploadWebDAV(file: URL, config: NASConfig, createDirs: Bool) throws -> String {
        let scheme = config.port == 443 || config.port == 0 ? "https" : "http"
        let port = config.effectivePort
        let remotePath = encodePath(config.path, trailingSlash: true)
        let fileNameNFC = normalizeNFC(file.lastPathComponent)
        let encodedName = encodeFileName(fileNameNFC)
        if createDirs {
            let dirURL = "\(scheme)://\(config.host):\(port)\(remotePath)"
            _ = try? runCurl(args: ["-X", "MKCOL", dirURL, "--connect-timeout", "10", "-s", "--insecure"], config: config)
        }
        let url = "\(scheme)://\(config.host):\(port)\(remotePath)\(encodedName)"

        let args = ["-T", file.path, url, "--connect-timeout", "15", "-s", "-S", "--fail", "--insecure"]
        let res = try runCurl(args: args, config: config)
        guard res.status == 0 else {
            let msg = res.stderr.isEmpty ? "WebDAV upload failed" : res.stderr
            throw NASError(message: "WebDAV upload failed: \(msg)")
        }
        return fileNameNFC
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
