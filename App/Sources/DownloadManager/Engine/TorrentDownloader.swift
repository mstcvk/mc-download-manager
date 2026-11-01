import Foundation

/// Runs one aria2 process per torrent; its control files stay beside the payload for resume.
enum TorrentDownloader {
    static func isMagnet(_ url: URL) -> Bool {
        normalizedMagnet(url) != nil
    }

    static func normalizedMagnet(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "magnet",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == nil, parts.path.isEmpty else { return nil }
        guard let topic = (parts.queryItems ?? []).first(where: { item in
            guard item.name.lowercased() == "xt", let value = item.value,
                  value.lowercased().hasPrefix("urn:btih:") else { return false }
            let hash = String(value.dropFirst(9))
            return (hash.count == 40 && hash.allSatisfy { "0123456789abcdefABCDEF".contains($0) })
                || (hash.count == 32 && hash.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz234567".contains($0) })
        }), let value = topic.value else { return nil }
        // aria2's URI parser is case-sensitive; pass a canonical v1 topic.
        let hash = String(value.dropFirst(9))
        parts.scheme = "magnet"
        parts.fragment = nil
        parts.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:" + (hash.count == 32 ? hash.uppercased() : hash.lowercased()))]
            + (parts.queryItems ?? []).filter { $0.name.lowercased() != "xt" }
        return parts.url
    }

    static func accepts(_ url: URL) -> Bool {
        isMagnet(url) || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil)
    }

    static func name(for url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "dn" })?.value ?? "Torrent"
    }

    static func directory(for item: DownloadItem) -> URL {
        item.directory.appendingPathComponent("Torrent-\(item.id.uuidString)", isDirectory: true)
    }

    static func locate() -> String? {
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aria2c").path,
                     "/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/aria2c" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func metadataDirectory(for item: DownloadItem) -> URL {
        directory(for: item).appendingPathComponent(".metadata", isDirectory: true)
    }

    static func metadataFile(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "torrent" }
        guard files.count == 1,
              try files[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try files[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DownloadFailure(message: String(localized: "Torrent metadata could not be read."))
        }
        return files[0]
    }

    static func metadataData(at url: URL) throws -> Data {
        guard url.isFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DownloadFailure(message: String(localized: "Torrent metadata could not be read."))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else {
            throw DownloadFailure(message: String(localized: "Invalid or unsupported torrent metadata."))
        }
        return data
    }

    static func arguments(url: URL, directory: URL, metadataOnly: Bool = false, selectedFiles: [Int]? = nil) -> [String] {
        var result = ["--no-conf=true", "--no-netrc=true", "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
         "--dir=\(directory.path)", "--seed-time=0", "--check-integrity=true",
         "--auto-save-interval=1", "--enable-color=false", "--human-readable=false",
         "--summary-interval=1", "--show-console-readout=true", "--console-log-level=notice",
         "--download-result=full", "--bt-save-metadata=\(metadataOnly)", "--bt-metadata-only=\(metadataOnly)", "--allow-overwrite=false",
         "--auto-file-renaming=false", "--listen-port=49152-65535", "--dht-listen-port=49152-65535",
         "--dht-file-path=\(directory.appendingPathComponent(".dht.dat").path)",
         "--dht-file-path6=\(directory.appendingPathComponent(".dht6.dat").path)"]
        if let selectedFiles {
            result.append("--select-file=" + selectedFiles.sorted().map(String.init).joined(separator: ","))
        }
        return result + ["--", url.isFileURL ? url.path : (normalizedMagnet(url) ?? url).absoluteString]
    }

    // shortcut: aria2's numeric console format, use RPC if its output format changes.
    static func progress(in line: String) -> (received: Int64, total: Int64, speed: Double)? {
        guard !line.contains("[METADATA]"),
              let regex = try? NSRegularExpression(pattern: #"\[#[a-fA-F0-9]+\s+(\d+)B?/(\d+)B?\([^)]*\).*?\bDL:(\d+)B?"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let values = (1...3).compactMap { Range(match.range(at: $0), in: line).flatMap { Int64(line[$0]) } }
        guard values.count == 3, values[1] > 0 else { return nil }
        return (min(values[0], values[1]), values[1], Double(values[2]))
    }

    /// Output and completion arrive in order on the main queue, including after termination.
    static func launch(executable: String, url: URL, directory: URL,
                       metadataOnly: Bool = false, selectedFiles: [Int]? = nil,
                       onLine: @escaping (String) -> Void,
                       onFinish: @escaping (Int32) -> Void) throws -> Process {
        if let selectedFiles, selectedFiles.isEmpty || selectedFiles.contains(where: { $0 <= 0 }) {
            throw DownloadFailure(message: String(localized: "Select at least one torrent file."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(url: url, directory: directory, metadataOnly: metadataOnly, selectedFiles: selectedFiles)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().async {
            var pending = Data()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let line = String(decoding: pending[..<end], as: UTF8.self)
                    pending.removeSubrange(...end)
                    if !line.isEmpty { DispatchQueue.main.async { onLine(line) } }
                }
                if pending.count > 65536 { pending.removeAll() }
            }
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { onLine(line) }
            }
            process.waitUntilExit()
            DispatchQueue.main.async { onFinish(process.terminationStatus) }
        }
        return process
    }
}

/// Bounded bencode reader for metadata supplied by peers. File indexes preserve torrent order.
private indirect enum BencodeValue {
    case bytes(Data), integer(Int64), list([BencodeValue]), dictionary([String: BencodeValue])
    var dictionary: [String: BencodeValue]? { if case .dictionary(let value) = self { return value }; return nil }
    var list: [BencodeValue]? { if case .list(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    var data: Data? { if case .bytes(let value) = self { return value }; return nil }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

private struct BencodeReader {
    let bytes: [UInt8]
    var offset = 0
    var remainingValues = 200_000
    static var invalid: DownloadFailure { DownloadFailure(message: String(localized: "Invalid or unsupported torrent metadata.")) }

    mutating func read(depth: Int = 0) throws -> BencodeValue {
        guard depth < 32, offset < bytes.count, remainingValues > 0 else { throw Self.invalid }
        remainingValues -= 1
        let tag = bytes[offset]
        offset += 1
        if tag == 105 {
            let start = offset
            while offset < bytes.count && bytes[offset] != 101 { offset += 1 }
            guard offset < bytes.count, let number = Int64(String(decoding: bytes[start..<offset], as: UTF8.self)),
                  String(number) == String(decoding: bytes[start..<offset], as: UTF8.self) else { throw Self.invalid }
            offset += 1
            return .integer(number)
        }
        if tag == 108 || tag == 100 {
            var list: [BencodeValue] = []
            var dictionary: [String: BencodeValue] = [:]
            while offset < bytes.count && bytes[offset] != 101 {
                if tag == 108 { list.append(try read(depth: depth + 1)) }
                else {
                    guard let key = try read(depth: depth + 1).string, dictionary[key] == nil else { throw Self.invalid }
                    dictionary[key] = try read(depth: depth + 1)
                }
            }
            guard offset < bytes.count else { throw Self.invalid }
            offset += 1
            return tag == 108 ? .list(list) : .dictionary(dictionary)
        }
        guard (48...57).contains(tag) else { throw Self.invalid }
        let start = offset - 1
        while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
        guard offset < bytes.count, bytes[offset] == 58,
              let count = Int(String(decoding: bytes[start..<offset], as: UTF8.self)), count >= 0,
              String(count) == String(decoding: bytes[start..<offset], as: UTF8.self),
              count <= bytes.count - offset - 1 else { throw Self.invalid }
        offset += 1
        let data = Data(bytes[offset..<offset + count])
        offset += count
        return .bytes(data)
    }
}

extension TorrentDownloader {
    static func files(in data: Data) throws -> [TorrentFile] {
        guard data.count <= 16 * 1024 * 1024 else { throw BencodeReader.invalid }
        var reader = BencodeReader(bytes: Array(data))
        guard let root = try reader.read().dictionary, reader.offset == data.count,
              let info = root["info"]?.dictionary,
              let name = (info["name.utf-8"] ?? info["name"])?.string else { throw BencodeReader.invalid }
        func component(_ name: String) throws -> String {
            guard !name.isEmpty, name != ".", name != "..",
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !name.contains("/"), !name.contains("\\"), !name.contains(":") else { throw BencodeReader.invalid }
            return name
        }
        let base = try component(name)
        // Keep torrent payloads separate from the engine's own metadata and DHT files.
        guard ![".metadata", ".dht.dat", ".dht6.dat"].contains(base.lowercased()) else { throw BencodeReader.invalid }
        var files: [TorrentFile] = []
        if let entries = info["files"]?.list {
            guard info["length"] == nil else { throw BencodeReader.invalid }
            for (index, entry) in entries.enumerated() {
                guard let file = entry.dictionary, let length = file["length"]?.integer, length >= 0,
                      let path = (file["path.utf-8"] ?? file["path"])?.list, !path.isEmpty,
                      !(file["attr"]?.string?.contains("l") ?? false) else { throw BencodeReader.invalid }
                let names = try path.map { value -> String in
                    guard let name = value.string else { throw BencodeReader.invalid }
                    return try component(name)
                }
                files.append(TorrentFile(id: index + 1, path: ([base] + names).joined(separator: "/"), length: length))
            }
        } else {
            guard info["files"] == nil, !(info["attr"]?.string?.contains("l") ?? false),
                  let length = info["length"]?.integer, length >= 0 else { throw BencodeReader.invalid }
            files = [TorrentFile(id: 1, path: base, length: length)]
        }
        // shortcut: reject case collisions on every volume; use volume rules if case-sensitive torrents are needed.
        let paths = files.map {
            $0.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) + "/"
        }.sorted()
        guard !paths.isEmpty else { throw BencodeReader.invalid }
        for (parent, next) in zip(paths, paths.dropFirst()) {
            guard !next.hasPrefix(parent) else { throw BencodeReader.invalid }
        }
        var total: Int64 = 0
        for file in files {
            let sum = total.addingReportingOverflow(file.length)
            guard !sum.overflow else { throw BencodeReader.invalid }
            total = sum.partialValue
        }
        guard let pieceLength = info["piece length"]?.integer, pieceLength > 0, pieceLength <= Int64(Int32.max),
              let pieces = info["pieces"]?.data else { throw BencodeReader.invalid }
        let pieceCount = total / pieceLength + (total % pieceLength == 0 ? 0 : 1)
        guard pieceCount <= Int64.max / 20, Int64(pieces.count) == pieceCount * 20 else { throw BencodeReader.invalid }
        return files
    }
}
