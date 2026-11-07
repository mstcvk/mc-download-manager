import Foundation

/// yt-dlp sarmalayıcısı. Uygulama içine gömülü ikiliyi (Contents/Helpers) tercih eder,
/// yoksa sistemdeki yt-dlp'yi arar.
enum VideoDownloader {

    static var helpersDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    }

    static func locateYtDlp(custom: String) -> String? {
        let candidates = [
            custom,
            ToolInstaller.userYtDlpPath,
            helpersDirectory.appendingPathComponent("yt-dlp").path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp",
        ]
        for c in candidates where !c.isEmpty && FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func locateFfmpeg() -> String? {
        let candidates = [
            helpersDirectory.appendingPathComponent("ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// deno is the JavaScript runtime yt-dlp uses to solve YouTube's n/signature challenges.
    /// Without it YouTube downloads fail or lose formats (see https://github.com/yt-dlp/yt-dlp/wiki/EJS).
    static func locateDeno() -> String? {
        let candidates = [
            ToolInstaller.userDenoPath,
            helpersDirectory.appendingPathComponent("deno").path,
            "/opt/homebrew/bin/deno",
            "/usr/local/bin/deno",
            NSHomeDirectory() + "/.deno/bin/deno",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// YouTube rejects the signed-in clients yt-dlp picks when cookies are passed
    /// ("The page needs to be reloaded", yt-dlp#17389); the same video usually works without cookies.
    static func isSignedInClientFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("page needs to be reloaded")
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [helpersDirectory.path, "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// Combines the per-download cookie file (from the browser extension) with the shared
    /// site-login cookie file into one temporary Netscape file. The site-login jar is only
    /// attached when the target host belongs to one of the domains the user signed in to.
    static func hasCookies(itemCookies: String?, targetHost: String?) -> Bool {
        if let c = itemCookies, FileManager.default.fileExists(atPath: c) { return true }
        let host = targetHost?.lowercased() ?? ""
        return SiteLoginManager.shared.domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func mergedCookieFile(itemCookies: String?, targetHost: String?) -> String? {
        let item = itemCookies.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let host = targetHost?.lowercased() ?? ""
        let siteMatches = SiteLoginManager.shared.domains.contains { host == $0 || host.hasSuffix("." + $0) }
        let site = siteMatches ? SiteLoginManager.cookieFilePath : nil
        switch (item, site) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?):
            let body = ((try? String(contentsOfFile: b, encoding: .utf8)) ?? "") + "\n" + ((try? String(contentsOfFile: a, encoding: .utf8)) ?? "")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mcdm-cookies-\(UUID().uuidString).txt")
            guard (try? body.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return a }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            return tmp.path
        }
    }

    struct Progress {
        var downloaded: Int64
        var total: Int64
        var speed: Double
    }

    /// Turns a yt-dlp log line into a user-facing phase description, if it marks a new phase.
    static func stage(for line: String) -> String? {
        if line.hasPrefix("[download] Destination:") {
            let name = line.replacingOccurrences(of: "[download] Destination: ", with: "")
            let lower = name.lowercased()
            // yt-dlp names intermediate files <title>.f<formatid>.<ext>
            if let r = lower.range(of: "\\.f[0-9]+[-a-z0-9]*\\.(m4a|webm|opus|mp3|aac|ogg)$", options: .regularExpression), r.upperBound == lower.endIndex {
                return String(localized: "Downloading audio…")
            }
            if lower.range(of: "\\.f[0-9]+[-a-z0-9]*\\.[a-z0-9]+$", options: .regularExpression) != nil {
                return String(localized: "Downloading video…")
            }
            return String(localized: "Downloading…")
        }
        if line.hasPrefix("[Merger]") { return String(localized: "Merging video and audio (ffmpeg)…") }
        if line.hasPrefix("[VideoRemuxer]") || line.hasPrefix("[VideoConvertor]") { return String(localized: "Converting container (ffmpeg)…") }
        if line.hasPrefix("[ExtractAudio]") { return String(localized: "Extracting audio (ffmpeg)…") }
        if line.hasPrefix("MCFMT|") {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6 else { return nil }
            var parts: [String] = []
            if p[1] != "NA", !p[1].isEmpty { parts.append(p[1]) }
            if p[2] != "NA" { parts.append(p[2].uppercased()) }
            if let v = p[3].split(separator: ".").first, p[3] != "NA", p[3] != "none" { parts.append(String(v)) }
            if let n = Double(p[5]), n > 0 { parts.append("~" + Fmt.size(Int64(n))) }
            return String(localized: "Selected: \(parts.joined(separator: " · "))")
        }
        if line.contains("has already been downloaded") { return String(localized: "File already downloaded") }
        return nil
    }

    @discardableResult
    static func run(executable: String,
                    url: URL,
                    outputDir: URL,
                    formatArgs: [String],
                    headers: [String: String],
                    cookieFile: String?,
                    useCookies: Bool = true,
                    onProgress: @escaping (Progress) -> Void,
                    onLine: @escaping (String) -> Void,
                    onFile: ((String) -> Void)? = nil,
                    onFinish: @escaping (Result<String?, Error>) -> Void) -> Process {

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        var args = [
            "--newline", "--no-playlist", "--no-colors", "--progress", "--no-simulate", "--no-mtime", "--no-quiet",
            "-N", "4",
            "-o", outputDir.appendingPathComponent("%(title).150B [%(id)s].%(ext)s").path,
            "--progress-template",
            "download:DMP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s",
            "--print", "after_move:filepath",
            "--print", "before_dl:MCFMT|%(resolution)s|%(ext)s|%(vcodec)s|%(acodec)s|%(filesize_approx)s|%(format_id)s|%(duration)s",
        ]
        args += formatArgs
        if let ff = locateFfmpeg() { args += ["--ffmpeg-location", ff] }
        if let ua = headers["User-Agent"], !ua.isEmpty { args += ["--user-agent", ua] }
        if let ref = headers["Referer"], !ref.isEmpty { args += ["--referer", ref] }
        if useCookies, let cf = mergedCookieFile(itemCookies: cookieFile, targetHost: url.host) { args += ["--cookies", cf] }
        if let deno = locateDeno() { args += ["--js-runtimes", "deno:" + deno] }
        args.append(url.absoluteString)
        p.arguments = args
        p.environment = environment()
        p.currentDirectoryURL = outputDir

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let lock = NSRecursiveLock()   // drain() holds it while handle() re-enters for finalPath/lastError
        var finalPath: String?
        var lastError: String?
        var outBuf = Data()
        var errBuf = Data()

        func handle(line raw: String, isError: Bool) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            if line.hasPrefix("DMP|") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 5 else { return }
                func num(_ s: String) -> Int64 { Int64(Double(s) ?? -1) }
                let downloaded = max(0, num(parts[1]))
                var total = num(parts[2])
                if total <= 0 { total = num(parts[3]) }
                onProgress(Progress(downloaded: downloaded, total: total, speed: max(0, Double(parts[4]) ?? 0)))
                return
            }
            if line.hasPrefix("/") && FileManager.default.fileExists(atPath: line) {
                lock.lock(); finalPath = line; lock.unlock()
                onFile?(line)
            }
            if isError && line.hasPrefix("ERROR") {
                lock.lock(); lastError = line; lock.unlock()
            }
            onLine(line)
        }

        func drain(_ buffer: inout Data, _ incoming: Data, isError: Bool) {
            buffer.append(incoming)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8) { handle(line: s, isError: isError) }
            }
        }

        // EOF on both pipes is signalled through the group; termination waits for it (with a timeout)
        // instead of a blocking readDataToEndOfFile(), which can hang if a grandchild keeps the pipe open.
        let eof = DispatchGroup()
        eof.enter(); eof.enter()
        out.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; eof.leave(); return }
            lock.lock(); drain(&outBuf, d, isError: false); lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; eof.leave(); return }
            lock.lock(); drain(&errBuf, d, isError: true); lock.unlock()
        }

        p.terminationHandler = { proc in
            _ = eof.wait(timeout: .now() + 3)
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            drain(&outBuf, Data([0x0A]), isError: false)
            drain(&errBuf, Data([0x0A]), isError: true)
            let path = finalPath
            let errText = lastError
            lock.unlock()
            if proc.terminationStatus == 0 {
                onFinish(.success(path))
            } else {
                onFinish(.failure(DownloadFailure(message: errText ?? String(localized: "yt-dlp exited with code \(proc.terminationStatus)"))))
            }
        }

        do {
            try p.run()
        } catch {
            onFinish(.failure(error))
        }
        return p
    }
}
