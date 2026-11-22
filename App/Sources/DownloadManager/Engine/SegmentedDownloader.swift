import Foundation

struct ProbeResult {
    var totalBytes: Int64
    var supportsRanges: Bool
    var suggestedFileName: String?
    var contentType: String?
    var finalURL: URL?
}

/// Tek bir dosyayı N paralel HTTP Range isteğiyle indirir.
/// Birden fazla ağ arayüzü (`config.interfaces.count >= 2`) verildiğinde, her bağlantıyı
/// ayrı bir ağ arayüzüne (`en0`, `en5`, `en7` vb.) bağlayarak bant genişliklerini birleştirir
/// ve boşa çıkan hızlı bağlantılarla kalan büyük parçaları dinamik olarak ikiye böler (work-stealing).
/// Tüm durum değişiklikleri `serialQueue` / `delegateQueue` (seri) üzerinde yapılır; kilit gerekmez.
final class SegmentedDownloader: NSObject, URLSessionDataDelegate {

    struct Configuration {
        var url: URL
        var headers: [String: String]
        var partURL: URL
        var segmentCount: Int
        var minSegmentSize: Int64 = 512 * 1024
        var resumeSegments: [SegmentInfo] = []
        var resumeTotal: Int64 = -1
        /// Active network interfaces to combine. When 2 or more are supplied,
        /// multi-network CurlStreamTask mode is used; otherwise standard URLSession is used.
        var interfaces: [NetworkInterfaceInfo] = []
    }

    private enum Mode { case idle, probing, multi, single }

    var onProbe: ((ProbeResult) -> Void)?
    var onProgress: ((Int64, [SegmentInfo]) -> Void)?
    var onNetworkBytes: (([String: Int64]) -> Void)?
    var onFinish: ((Result<Void, Error>) -> Void)?

    private let config: Configuration
    private let serialQueue = DispatchQueue(label: "dm.segmented-downloader")
    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.underlyingQueue = serialQueue
        q.name = "dm.segmented-downloader"
        return q
    }()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 32
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.waitsForConnectivity = true
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c, delegate: self, delegateQueue: delegateQueue)
    }()

    private var mode: Mode = .idle
    private var requestURL: URL
    private var expectedETag: String?
    private var expectedTotal: Int64 = -1
    private var segments: [SegmentInfo] = []
    private var segmentTasks: [Int: (task: URLSessionDataTask, index: Int, requestedStart: Int64, requestedEnd: Int64)] = [:]
    private var retries: [Int: Int] = [:]
    private var pending: [Int] = []          // başlatılmayı bekleyen parça indeksleri
    private var streamCeiling: Int { max(1, config.segmentCount) }
    private var activeLimit = 1              // aynı anda açık bağlantı üst sınırı (429/503'te düşer)
    private var throttledUntil = Date.distantPast
    private static let maxAttempts = 12
    private var probeTask: URLSessionDataTask?
    private var curlProbeTask: CurlStreamTask?
    private var singleTask: URLSessionDataTask?
    private var curlSingleTask: CurlStreamTask?
    private var curlSingleInterface: NetworkInterfaceInfo?
    private var singleReceived: Int64 = 0
    private var singleTotal: Int64 = -1
    private var fileHandle: FileHandle?
    private var stopped = false
    private var finished = false
    private var fallbackDone = false
    /// The Range probe was refused: the plain GET (what a browser sends) also has to report the probe result.
    private var probeFromSingle = false
    private var lastReport = Date.distantPast

    // MARK: - Multi-network state (used when currentInterfaces is non-empty)
    private var currentInterfaces: [NetworkInterfaceInfo]
    private var forceSystemTransport = false
    private var useMultiNetwork: Bool { !forceSystemTransport && !currentInterfaces.isEmpty }
    private var curlTasks: [Int: (task: CurlStreamTask, index: Int, iface: NetworkInterfaceInfo)] = [:]
    private var disabledInterfaces: Set<String> = []
    private var interfaceErrorStreak: [String: Int] = [:]
    private var bytesByInterface: [String: Int64] = [:]
    private var duplicateDisplayNames: Set<String> = []

    init(configuration: Configuration) {
        config = configuration
        requestURL = configuration.url
        currentInterfaces = configuration.interfaces
        let counts = Dictionary(grouping: configuration.interfaces, by: \.displayName)
        duplicateDisplayNames = Set(counts.filter { $0.value.count > 1 }.keys)
        super.init()
    }

    private func label(for iface: NetworkInterfaceInfo) -> String {
        duplicateDisplayNames.contains(iface.displayName) ? iface.shortLabel : iface.displayName
    }

    private var healthyInterfaces: [NetworkInterfaceInfo] {
        currentInterfaces.filter { !disabledInterfaces.contains($0.device) }
    }

    /// Dynamically updates the active network interfaces during a running download.
    /// Newly plugged-in interfaces immediately steal halves of the largest in-flight segments;
    /// unplugged interfaces have their in-flight tasks cancelled and reassigned to remaining interfaces.
    func updateInterfaces(_ newInterfaces: [NetworkInterfaceInfo]) {
        serialQueue.async { [self] in
            guard !stopped, !finished, currentInterfaces != newInterfaces else { return }
            let oldDevices = Set(currentInterfaces.map(\.device))
            let newDevices = Set(newInterfaces.map(\.device))
            let added = newDevices.subtracting(oldDevices)
            let removed = oldDevices.subtracting(newDevices)

            currentInterfaces = newInterfaces
            let counts = Dictionary(grouping: newInterfaces, by: \.displayName)
            duplicateDisplayNames = Set(counts.filter { $0.value.count > 1 }.keys)

            for dev in added {
                disabledInterfaces.remove(dev)
                interfaceErrorStreak[dev] = 0
            }

            if mode == .single, let singleIface = curlSingleInterface, removed.contains(singleIface.device) {
                curlSingleTask?.cancel()
                curlSingleTask = nil
                curlSingleInterface = nil
                closeFile()
                guard openFile(create: true, preallocate: nil) else { return }
                singleTotal = -1
                launchSingle()
                return
            }

            guard mode == .multi else { return }

            for (taskID, entry) in Array(curlTasks) where removed.contains(entry.iface.device) {
                curlTasks.removeValue(forKey: taskID)
                entry.task.cancel()
                if entry.index < segments.count, !segments[entry.index].isDone, !pending.contains(entry.index) {
                    pending.insert(entry.index, at: 0)
                }
            }

            if throttledUntil.timeIntervalSinceNow > 0 {
                activeLimit = min(streamCeiling, max(1, activeLimit))
            } else {
                activeLimit = streamCeiling
            }

            fillSlots()
        }
    }

    // MARK: - Kontrol

    func start() {
        serialQueue.async { [self] in
            let canResume = config.resumeTotal > 0
                && !config.resumeSegments.isEmpty
                && FileManager.default.fileExists(atPath: config.partURL.path)
            if canResume {
                segments = config.resumeSegments
                expectedTotal = config.resumeTotal
                guard openFile(create: false, preallocate: nil) else { return }
                mode = .multi
                launchPendingSegments()
            } else {
                probe()
            }
        }
    }

    /// Duraklat veya iptal et. Son parça durumu `onProgress` ile bildirilir.
    func stop() {
        serialQueue.async { [self] in
            guard !finished, !stopped else { return }
            stopped = true
            cancelAllCurlTasks()
            session.invalidateAndCancel()
            closeFile()
            onProgress?(currentReceived(), segments)
            if !bytesByInterface.isEmpty { onNetworkBytes?(bytesByInterface) }
        }
    }

    private func cancelAllCurlTasks() {
        curlProbeTask?.cancel()
        curlProbeTask = nil
        curlSingleTask?.cancel()
        curlSingleTask = nil
        curlSingleInterface = nil
        let tasks = curlTasks
        curlTasks = [:]
        tasks.values.forEach { $0.task.cancel() }
    }

    // MARK: - Yardımcılar

    private func currentReceived() -> Int64 {
        mode == .single ? singleReceived : segments.reduce(0) { $0 + $1.received }
    }

    private static let credentialHeaders: Set<String> = ["cookie", "authorization", "proxy-authorization"]

    /// Credentials (Cookie/Authorization) are only sent to the host the download was requested for,
    /// never to a host reached through a redirect.
    private func sameOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host?.lowercased() == config.url.host?.lowercased() && url.scheme?.lowercased() == config.url.scheme?.lowercased()
    }

    private func makeRequest(range: String?) -> URLRequest {
        var r = URLRequest(url: requestURL)
        r.httpMethod = "GET"
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let allowCredentials = sameOrigin(requestURL)
        for (k, v) in config.headers where allowCredentials || !Self.credentialHeaders.contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            r.setValue(range, forHTTPHeaderField: "Range")
            if let expectedETag {
                r.setValue(expectedETag, forHTTPHeaderField: "If-Range")
            }
        }
        return r
    }

    private func probe() {
        mode = .probing
        let candidates = healthyInterfaces
        if !candidates.isEmpty {
            probeWithCurl(candidates: candidates, index: 0)
        } else {
            probeWithURLSession()
        }
    }

    private func probeWithURLSession() {
        forceSystemTransport = true
        let t = session.dataTask(with: makeRequest(range: "bytes=0-0"))
        probeTask = t
        t.resume()
    }

    private func probeWithCurl(candidates: [NetworkInterfaceInfo], index: Int) {
        guard !stopped, !finished else { return }
        guard index < candidates.count else {
            probeWithURLSession()
            return
        }
        let iface = candidates[index]
        var capturedResponse: CurlHTTPResponse?
        let task = CurlStreamTask(
            url: requestURL,
            headers: config.headers,
            range: "0-0",
            interfaceDevice: iface.device,
            interfaceAddress: iface.primaryAddress,
            ipv4Only: iface.ipv4Address != nil && iface.ipv6Address == nil,
            originHost: config.url.host,
            originScheme: config.url.scheme,
            onHeaders: { resp in
                capturedResponse = resp
                return false // stop right after headers for probe
            },
            onData: { _ in false },
            onComplete: { [weak self] result in
                guard let self else { return }
                self.serialQueue.async {
                    guard !self.stopped, !self.finished, self.mode == .probing else { return }
                    self.curlProbeTask = nil
                    if let resp = capturedResponse, (200...299).contains(resp.statusCode) {
                        self.handleCurlProbe(resp)
                    } else if case .failure(let error as DownloadFailure) = result {
                        self.fail(error)
                    } else if index + 1 < candidates.count {
                        self.probeWithCurl(candidates: candidates, index: index + 1)
                    } else if let resp = capturedResponse {
                        self.handleCurlProbe(resp)
                    } else {
                        self.probeWithURLSession()
                    }
                }
            }
        )
        curlProbeTask = task
        task.start()
    }

    private func handleCurlProbe(_ resp: CurlHTTPResponse) {
        let status = resp.statusCode
        guard (200...299).contains(status) else {
            if !fallbackDone, !Self.isThrottle(status) {
                fallbackDone = true
                probeFromSingle = true
                guard openFile(create: true, preallocate: nil) else { return }
                mode = .single
                launchSingle()
            } else {
                fail(HTTPStatusError(status: status))
            }
            return
        }

        var total: Int64 = -1
        var ranges = false
        if status == 206,
           let cr = resp.header("content-range"),
           let slash = cr.lastIndex(of: "/"),
           let t = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            total = t
            ranges = true
        } else {
            if resp.expectedContentLength > 0 {
                total = resp.expectedContentLength
            }
            let accept = resp.header("accept-ranges")?.lowercased() ?? ""
            ranges = total > 0 && accept.contains("bytes")
        }
        requestURL = resp.finalURL

        let name = Self.fileName(fromContentDisposition: resp.header("content-disposition"))
        let ctype = resp.header("content-type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
        onProbe?(ProbeResult(totalBytes: total, supportsRanges: ranges,
                             suggestedFileName: name, contentType: ctype, finalURL: resp.finalURL))

        let count = ranges ? max(1, min(streamCeiling, Int(total / config.minSegmentSize))) : 1
        let strongETag = Self.strongETag(from: resp.header("etag"))
        let canValidateMulti = !useMultiNetwork || strongETag != nil
        if ranges && count > 1 && canValidateMulti {
            expectedETag = strongETag
            expectedTotal = total
            segments = Self.makeSegments(total: total, count: count)
            guard openFile(create: true, preallocate: total) else { return }
            mode = .multi
            launchPendingSegments()
        } else {
            singleTotal = total
            guard openFile(create: true, preallocate: nil) else { return }
            mode = .single
            launchSingle()
        }
    }

    private func handleProbe(_ http: HTTPURLResponse) {
        let status = http.statusCode
        guard (200...299).contains(status) else {
            // Some servers (signed / one-shot links, anti download-manager checks) refuse a Range request
            // but serve the plain GET a browser would send: try that once before giving up.
            if !fallbackDone, !Self.isThrottle(status) {
                fallbackDone = true
                probeFromSingle = true
                guard openFile(create: true, preallocate: nil) else { return }
                mode = .single
                launchSingle()
            } else {
                fail(HTTPStatusError(status: status))
            }
            return
        }

        var total: Int64 = -1
        var ranges = false
        if status == 206,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"),
           let t = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            total = t
            ranges = true
        } else {
            if let cl = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(cl) {
                total = n
            } else if http.expectedContentLength > 0 {
                total = http.expectedContentLength
            }
            let accept = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
            ranges = total > 0 && accept.contains("bytes")
        }
        if let u = http.url { requestURL = u }

        let name = Self.fileName(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
        let ctype = http.value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
        onProbe?(ProbeResult(totalBytes: total, supportsRanges: ranges,
                             suggestedFileName: name, contentType: ctype, finalURL: http.url))

        let count = ranges ? max(1, min(streamCeiling, Int(total / config.minSegmentSize))) : 1
        let strongETag = Self.strongETag(from: http.value(forHTTPHeaderField: "ETag"))
        let canValidateMulti = !useMultiNetwork || strongETag != nil
        if ranges && count > 1 && canValidateMulti {
            expectedETag = strongETag
            expectedTotal = total
            segments = Self.makeSegments(total: total, count: count)
            guard openFile(create: true, preallocate: total) else { return }
            mode = .multi
            launchPendingSegments()
        } else {
            singleTotal = total
            guard openFile(create: true, preallocate: nil) else { return }
            mode = .single
            launchSingle()
        }
    }

    static func makeSegments(total: Int64, count: Int) -> [SegmentInfo] {
        let size = total / Int64(count)
        return (0..<count).map { i in
            let start = Int64(i) * size
            let end = i == count - 1 ? total - 1 : start + size - 1
            return SegmentInfo(start: start, end: end, received: 0)
        }
    }

    private func openFile(create: Bool, preallocate: Int64?) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: config.partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if create || !fm.fileExists(atPath: config.partURL.path) {
                guard fm.createFile(atPath: config.partURL.path, contents: nil) else {
                    throw DownloadFailure(message: String(localized: "Could not create file: \(config.partURL.path)"), local: true)
                }
            }
            let fh = try FileHandle(forWritingTo: config.partURL)
            if let preallocate, preallocate > 0 { try fh.truncate(atOffset: UInt64(preallocate)) }
            fileHandle = fh
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func launchPendingSegments() {
        pending = segments.indices.filter { !segments[$0].isDone }
        activeLimit = streamCeiling
        if pending.isEmpty { finishSuccess() } else { fillSlots() }
    }

    private var activeTaskCount: Int {
        useMultiNetwork ? curlTasks.count : segmentTasks.count
    }

    /// Bekleyen parçaları, açık bağlantı sınırını aşmadan başlatır.
    /// Çoklu ağ modunda bekleyen parça kalmadığında, boşta kalan hızlı bağlantılar
    /// en çok verisi kalan aktif parçayı ikiye bölerek (work-stealing) devralır.
    private func fillSlots() {
        guard !stopped, !finished, mode == .multi else { return }
        let wait = throttledUntil.timeIntervalSinceNow
        if wait > 0 {
            serialQueue.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
                self?.fillSlots()
            }
            return
        }
        if useMultiNetwork && !pending.isEmpty && healthyInterfaces.isEmpty {
            fallbackToSingle()
            return
        }
        let effectiveLimit = min(activeLimit, streamCeiling)
        while !stopped, !finished, mode == .multi, activeTaskCount < effectiveLimit, !pending.isEmpty {
            let i = pending.removeFirst()
            if segments[i].isDone { continue }
            if useMultiNetwork {
                launchCurlSegment(i)
            } else {
                launchSegment(i)
            }
            if mode != .multi || stopped || finished { return }
        }
        // Work-stealing: if a fast interface finished early and slots are free, split the largest active segment.
        if useMultiNetwork && pending.isEmpty && !healthyInterfaces.isEmpty {
            while activeTaskCount < effectiveLimit, let newIdx = splitLargestActiveSegment() {
                launchCurlSegment(newIdx)
            }
        }
        if activeTaskCount == 0, pending.isEmpty { checkAllDone() }
    }

    /// Picks the healthy interface with the fewest active connections so faster interfaces
    /// naturally pull more work as soon as they finish a segment.
    private func leastLoadedInterface() -> NetworkInterfaceInfo? {
        let candidates = healthyInterfaces
        guard !candidates.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for entry in curlTasks.values {
            counts[entry.iface.device, default: 0] += 1
        }
        return candidates.min { a, b in
            counts[a.device, default: 0] < counts[b.device, default: 0]
        }
    }

    /// Splits the active segment with the most remaining bytes in half so a free worker
    /// (typically on a faster network interface) can download the back half in parallel.
    private func splitLargestActiveSegment() -> Int? {
        let minSplit = max(config.minSegmentSize * 2, 1024 * 1024) // at least 1 MB remaining
        var bestIndex: Int?
        var bestRemaining: Int64 = minSplit - 1

        for entry in curlTasks.values {
            let i = entry.index
            guard i < segments.count else { continue }
            let seg = segments[i]
            let remaining = seg.length - seg.received
            if remaining > bestRemaining {
                bestRemaining = remaining
                bestIndex = i
            }
        }

        guard let i = bestIndex else { return nil }
        var seg = segments[i]
        let currentPos = seg.start + seg.received
        let remaining = seg.length - seg.received
        guard remaining >= minSplit else { return nil }

        let oldEnd = seg.end
        let mid = currentPos + (remaining / 2)
        guard mid < oldEnd else { return nil }

        seg.end = mid
        segments[i] = seg

        let newSeg = SegmentInfo(start: mid + 1, end: oldEnd, received: 0)
        segments.append(newSeg)
        return segments.count - 1
    }

    /// Sunucu sınırlaması (429/503): bağlantı sayısını düşür, parçayı kuyruğa geri koy.
    private func throttle(segment i: Int, status: Int) {
        activeLimit = max(1, min(activeLimit, activeTaskCount) - 1)
        let attempt = retries[i, default: 0] + 1
        retries[i] = attempt
        guard attempt <= Self.maxAttempts else {
            fail(HTTPStatusError(status: status))
            return
        }
        throttledUntil = Date().addingTimeInterval(min(15, 1.5 * Double(attempt)))
        if !pending.contains(i) { pending.insert(i, at: 0) }
        fillSlots()
    }

    private func launchSegment(_ i: Int) {
        let seg = segments[i]
        let requestedStart = seg.start + seg.received
        let requestedEnd = seg.end
        let t = session.dataTask(with: makeRequest(range: "bytes=\(requestedStart)-\(requestedEnd)"))
        segmentTasks[t.taskIdentifier] = (t, i, requestedStart, requestedEnd)
        t.resume()
    }

    private func launchCurlSegment(_ i: Int) {
        guard let iface = leastLoadedInterface() else {
            // All interfaces were disabled; fall back to single-stream URLSession.
            fallbackToSingle()
            return
        }
        let seg = segments[i]
        let requestedStart = seg.start + seg.received
        let requestedEnd = seg.end
        let rangeStr = "\(requestedStart)-\(requestedEnd)"
        let ifaceLabel = label(for: iface)
        segments[i].interfaceDevice = iface.device
        segments[i].interfaceName = ifaceLabel

        var segHeaders = config.headers
        if let expectedETag {
            segHeaders["If-Range"] = expectedETag
        }

        var taskID = 0
        let task = CurlStreamTask(
            url: requestURL,
            headers: segHeaders,
            range: rangeStr,
            interfaceDevice: iface.device,
            interfaceAddress: iface.primaryAddress,
            ipv4Only: iface.ipv4Address != nil && iface.ipv6Address == nil,
            originHost: config.url.host,
            originScheme: config.url.scheme,
            onHeaders: { [weak self] resp in
                guard let self else { return false }
                return self.serialQueue.sync {
                    self.handleCurlHeaders(
                        taskID: taskID,
                        index: i,
                        iface: iface,
                        requestedStart: requestedStart,
                        requestedEnd: requestedEnd,
                        response: resp
                    )
                }
            },
            onData: { [weak self] data in
                guard let self else { return false }
                return self.serialQueue.sync {
                    self.handleCurlData(taskID: taskID, index: i, iface: iface, data: data)
                }
            },
            onComplete: { [weak self] result in
                guard let self else { return }
                self.serialQueue.async {
                    self.handleCurlComplete(taskID: taskID, index: i, iface: iface, result: result)
                }
            }
        )
        taskID = task.id
        curlTasks[taskID] = (task, i, iface)
        task.start()
    }

    private func handleCurlHeaders(
        taskID: Int,
        index i: Int,
        iface: NetworkInterfaceInfo,
        requestedStart: Int64,
        requestedEnd: Int64,
        response: CurlHTTPResponse
    ) -> Bool {
        guard !stopped, !finished, curlTasks[taskID] != nil else { return false }
        switch response.statusCode {
        case 206:
            guard isConsistentPartialResponse(
                etag: response.header("etag"),
                contentRange: response.header("content-range"),
                requestedStart: requestedStart,
                requestedEnd: requestedEnd
            ) else {
                curlTasks.removeValue(forKey: taskID)
                if fallbackDone {
                    fail(DownloadFailure(message: String(localized: "Server returned inconsistent file representation")))
                } else {
                    fallbackToSingle()
                }
                return false
            }
            retries[i] = 0
            interfaceErrorStreak[iface.device] = 0
            return true
        case 200:
            fallbackToSingle()
            return false
        case let s where Self.isThrottle(s):
            curlTasks.removeValue(forKey: taskID)
            throttle(segment: i, status: s)
            return false
        default:
            // 401/403/410 on a secondary interface often means the server locked the URL to one public IP.
            // Disable this interface for the current download and let healthy interfaces finish the segment.
            curlTasks.removeValue(forKey: taskID)
            if healthyInterfaces.contains(where: { $0.device != iface.device }) {
                disableInterface(iface.device)
                if i < segments.count, !segments[i].isDone, !pending.contains(i) {
                    pending.insert(i, at: 0)
                }
                fillSlots()
            } else if fallbackDone {
                fail(HTTPStatusError(status: response.statusCode))
            } else {
                fallbackToSingle()
            }
            return false
        }
    }

    private func disableInterface(_ device: String) {
        disabledInterfaces.insert(device)
        for (id, entry) in Array(curlTasks) where entry.iface.device == device {
            curlTasks.removeValue(forKey: id)
            entry.task.cancel()
            if entry.index < segments.count, !segments[entry.index].isDone, !pending.contains(entry.index) {
                pending.insert(entry.index, at: 0)
            }
        }
    }

    private func handleCurlData(taskID: Int, index i: Int, iface: NetworkInterfaceInfo, data: Data) -> Bool {
        guard !stopped, !finished, curlTasks[taskID] != nil, let fh = fileHandle, i < segments.count else { return false }
        var seg = segments[i]
        let remaining = seg.length - seg.received
        guard remaining > 0 else { return false }

        let chunk = Int64(data.count) > remaining ? data.prefix(Int(remaining)) : data
        do {
            try fh.seek(toOffset: UInt64(seg.start + seg.received))
            try fh.write(contentsOf: chunk)
            seg.received += Int64(chunk.count)
            segments[i] = seg
            let key = label(for: iface)
            bytesByInterface[key, default: 0] += Int64(chunk.count)
            interfaceErrorStreak[iface.device] = 0
        } catch {
            fail(error)
            return false
        }
        reportProgress()
        // If this segment was shortened by work-stealing and is now complete, stop the stream cleanly.
        return !seg.isDone
    }

    private func handleCurlComplete(taskID: Int, index i: Int, iface: NetworkInterfaceInfo, result: Result<Void, Error>) {
        guard !stopped, !finished else { return }
        guard curlTasks.removeValue(forKey: taskID) != nil else { return }

        if case .failure(let error) = result {
            if let ce = error as? CurlError, ce.isCancelled { return }
            if segments[i].isDone {
                fillSlots()
                return
            }
            let streak = interfaceErrorStreak[iface.device, default: 0] + 1
            interfaceErrorStreak[iface.device] = streak
            if streak >= 3, healthyInterfaces.contains(where: { $0.device != iface.device }) {
                disableInterface(iface.device)
            }
            retrySegment(i, after: error)
            return
        }

        if segments[i].isDone {
            activeLimit = min(streamCeiling, activeLimit + 1)
            fillSlots()
        } else {
            retrySegment(i, after: nil)
        }
    }

    private func launchSingle() {
        singleReceived = 0
        if useMultiNetwork, let iface = leastLoadedInterface() {
            var singleTaskID = 0
            let task = CurlStreamTask(
                url: requestURL,
                headers: config.headers,
                range: nil,
                interfaceDevice: iface.device,
                interfaceAddress: iface.primaryAddress,
                ipv4Only: iface.ipv4Address != nil && iface.ipv6Address == nil,
                originHost: config.url.host,
                originScheme: config.url.scheme,
                onHeaders: { [weak self] resp in
                    guard let self else { return false }
                    return self.serialQueue.sync {
                        guard !self.stopped, !self.finished, self.curlSingleTask?.id == singleTaskID else { return false }
                        guard (200...299).contains(resp.statusCode) else {
                            self.curlSingleTask = nil
                            self.curlSingleInterface = nil
                            self.fail(HTTPStatusError(status: resp.statusCode))
                            return false
                        }
                        self.singleTotal = resp.expectedContentLength > 0 ? resp.expectedContentLength : -1
                        if self.probeFromSingle {
                            self.probeFromSingle = false
                            self.requestURL = resp.finalURL
                            let ctype = resp.header("content-type")?
                                .components(separatedBy: ";").first?
                                .trimmingCharacters(in: .whitespaces)
                            self.onProbe?(ProbeResult(
                                totalBytes: self.singleTotal,
                                supportsRanges: false,
                                suggestedFileName: Self.fileName(fromContentDisposition: resp.header("content-disposition")),
                                contentType: ctype,
                                finalURL: resp.finalURL
                            ))
                        }
                        return true
                    }
                },
                onData: { [weak self] data in
                    guard let self else { return false }
                    return self.serialQueue.sync {
                        guard !self.stopped, !self.finished, self.curlSingleTask?.id == singleTaskID, let fh = self.fileHandle else {
                            return false
                        }
                        do {
                            try fh.seek(toOffset: UInt64(self.singleReceived))
                            try fh.write(contentsOf: data)
                            self.singleReceived += Int64(data.count)
                            let key = self.label(for: iface)
                            self.bytesByInterface[key, default: 0] += Int64(data.count)
                        } catch {
                            self.fail(error)
                            return false
                        }
                        self.reportProgress()
                        return true
                    }
                },
                onComplete: { [weak self] result in
                    guard let self else { return }
                    self.serialQueue.async {
                        guard !self.stopped, !self.finished, self.curlSingleTask?.id == singleTaskID else { return }
                        self.curlSingleTask = nil
                        self.curlSingleInterface = nil
                        if case .failure(let error) = result {
                            if let ce = error as? CurlError, ce.isCancelled { return }
                            if self.healthyInterfaces.contains(where: { $0.device != iface.device }) {
                                self.disabledInterfaces.insert(iface.device)
                                self.closeFile()
                                guard self.openFile(create: true, preallocate: nil) else { return }
                                self.singleTotal = -1
                                self.launchSingle()
                                return
                            }
                            self.fail(error)
                            return
                        }
                        if self.singleTotal > 0, self.singleReceived < self.singleTotal {
                            self.fail(DownloadFailure(message: String(localized: "Connection closed early (\(self.singleReceived)/\(self.singleTotal) bytes)")))
                            return
                        }
                        self.finishSuccess()
                    }
                }
            )
            singleTaskID = task.id
            curlSingleTask = task
            curlSingleInterface = iface
            task.start()
            return
        }
        curlSingleInterface = nil
        let t = session.dataTask(with: makeRequest(range: nil))
        singleTask = t
        t.resume()
    }

    private static func isThrottle(_ status: Int) -> Bool { [408, 425, 429, 500, 502, 503, 504].contains(status) }

    private static func strongETag(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("W/"),
              !trimmed.hasPrefix("w/") else {
            return nil
        }
        return trimmed
    }

    private static func isValidContentRange(
        _ header: String?,
        requestedStart: Int64,
        requestedEnd: Int64,
        expectedTotal: Int64
    ) -> Bool {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("bytes ") else {
            return false
        }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let rangeParts = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              let total = Int64(parts[1]) else {
            return false
        }
        guard start == requestedStart,
              end >= start,
              end <= requestedEnd else {
            return false
        }
        if expectedTotal > 0, total != expectedTotal {
            return false
        }
        return true
    }

    private func isConsistentPartialResponse(
        etag: String?,
        contentRange: String?,
        requestedStart: Int64,
        requestedEnd: Int64
    ) -> Bool {
        guard Self.isValidContentRange(
            contentRange,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            expectedTotal: expectedTotal
        ) else {
            return false
        }
        if let expectedETag {
            guard let responseETag = Self.strongETag(from: etag), responseETag == expectedETag else {
                return false
            }
        } else if useMultiNetwork {
            guard let responseETag = Self.strongETag(from: etag) else {
                return false
            }
            expectedETag = responseETag
        }
        return true
    }

    /// Sunucu Range'i yok sayıp 200 döndürdüyse ya da parça isteklerini reddettiyse tek akışa geç.
    private func fallbackToSingle() {
        guard !fallbackDone else { return }
        fallbackDone = true
        cancelAllCurlTasks()
        let old = segmentTasks
        segmentTasks = [:]
        old.values.forEach { $0.task.cancel() }
        segments = []
        pending = []
        closeFile()
        guard openFile(create: true, preallocate: nil) else { return }
        mode = .single
        launchSingle()
    }

    private func retrySegment(_ i: Int, after error: Error?) {
        let attempt = retries[i, default: 0] + 1
        retries[i] = attempt
        guard attempt <= Self.maxAttempts else {
            fail(error ?? DownloadFailure(message: String(localized: "Segment \(i + 1) could not be completed")))
            return
        }
        throttledUntil = max(throttledUntil, Date().addingTimeInterval(min(10, Double(attempt))))
        if !pending.contains(i) { pending.append(i) }
        fillSlots()
    }

    private func checkAllDone() {
        if !segments.isEmpty, segments.allSatisfy(\.isDone) { finishSuccess() }
    }

    private func finishSuccess() {
        guard !finished, !stopped else { return }
        finished = true
        cancelAllCurlTasks()
        closeFile()
        session.finishTasksAndInvalidate()
        onProgress?(currentReceived(), segments)
        if !bytesByInterface.isEmpty { onNetworkBytes?(bytesByInterface) }
        onFinish?(.success(()))
    }

    private func fail(_ error: Error) {
        guard !finished, !stopped else { return }
        finished = true
        cancelAllCurlTasks()
        closeFile()
        session.invalidateAndCancel()
        onProgress?(currentReceived(), segments)
        if !bytesByInterface.isEmpty { onNetworkBytes?(bytesByInterface) }
        onFinish?(.failure(error))
    }

    private func reportProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        onProgress?(currentReceived(), segments)
        if !bytesByInterface.isEmpty { onNetworkBytes?(bytesByInterface) }
    }

    private static func isCancelled(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        if !sameOrigin(req.url) {
            for h in Self.credentialHeaders { req.setValue(nil, forHTTPHeaderField: h) }
        }
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, !finished else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            fail(DownloadFailure(message: String(localized: "Invalid server response")))
            return
        }

        if dataTask == probeTask {
            completionHandler(.cancel)
            handleProbe(http)
            return
        }

        if let entry = segmentTasks[dataTask.taskIdentifier] {
            switch http.statusCode {
            case 206:
                guard isConsistentPartialResponse(
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    requestedStart: entry.requestedStart,
                    requestedEnd: entry.requestedEnd
                ) else {
                    completionHandler(.cancel)
                    if fallbackDone {
                        fail(DownloadFailure(message: String(localized: "Server returned inconsistent file representation")))
                    } else {
                        fallbackToSingle()
                    }
                    return
                }
                completionHandler(.allow)
                retries[entry.index] = 0
            case 200:
                completionHandler(.cancel)
                fallbackToSingle()
            case let s where Self.isThrottle(s):
                completionHandler(.cancel)
                segmentTasks[dataTask.taskIdentifier] = nil
                throttle(segment: entry.index, status: http.statusCode)
            default:
                // 401/403/410…: the server accepted the probe but refuses parallel connections — continue on one.
                completionHandler(.cancel)
                if fallbackDone { fail(HTTPStatusError(status: http.statusCode)) } else { fallbackToSingle() }
            }
            return
        }

        if dataTask == singleTask {
            guard (200...299).contains(http.statusCode) else {
                completionHandler(.cancel)
                fail(HTTPStatusError(status: http.statusCode))
                return
            }
            // The real GET may differ from the probe (dynamic responses); trust its Content-Length.
            singleTotal = http.expectedContentLength > 0 ? http.expectedContentLength : -1
            if probeFromSingle {
                probeFromSingle = false
                if let u = http.url { requestURL = u }
                let ctype = http.value(forHTTPHeaderField: "Content-Type")?
                    .components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces)
                onProbe?(ProbeResult(totalBytes: singleTotal, supportsRanges: false,
                                     suggestedFileName: Self.fileName(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition")),
                                     contentType: ctype, finalURL: http.url))
            }
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, !finished, let fh = fileHandle else { return }
        do {
            if let entry = segmentTasks[dataTask.taskIdentifier] {
                var seg = segments[entry.index]
                let remaining = seg.length - seg.received
                guard remaining > 0 else { return }
                let chunk = Int64(data.count) > remaining ? data.prefix(Int(remaining)) : data
                try fh.seek(toOffset: UInt64(seg.start + seg.received))
                try fh.write(contentsOf: chunk)
                seg.received += Int64(chunk.count)
                segments[entry.index] = seg
            } else if dataTask == singleTask {
                try fh.seek(toOffset: UInt64(singleReceived))
                try fh.write(contentsOf: data)
                singleReceived += Int64(data.count)
            } else {
                return
            }
        } catch {
            fail(error)
            return
        }
        reportProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped, !finished else { return }

        if task == probeTask {
            // Yanıt hiç gelmediyse (bağlantı hatası) başarısız say.
            if mode == .probing, let error { fail(error) }
            return
        }

        if let entry = segmentTasks.removeValue(forKey: task.taskIdentifier) {
            let i = entry.index
            if let error, Self.isCancelled(error) { return }
            if segments[i].isDone {
                activeLimit = min(config.segmentCount, activeLimit + 1)
                fillSlots()
            } else {
                retrySegment(i, after: error)
            }
            return
        }

        if task == singleTask {
            if let error {
                if !Self.isCancelled(error) { fail(error) }
                return
            }
            if singleTotal > 0, singleReceived < singleTotal {
                fail(DownloadFailure(message: String(localized: "Connection closed early (\(singleReceived)/\(singleTotal) bytes)")))
                return
            }
            finishSuccess()
        }
    }

    // MARK: - Content-Disposition

    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        // RFC 5987: filename*=UTF-8''dosya%20adi.zip
        if let r = header.range(of: "filename\\*\\s*=\\s*[^']*'[^']*'[^;]+", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let q = m.range(of: "''") {
                let enc = String(m[q.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let d = enc.removingPercentEncoding, !d.isEmpty {
                    return d.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        if let r = header.range(of: "filename\\s*=\\s*\"[^\"]*\"", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
                let v = String(m[m.index(after: q1)..<q2])
                return v.isEmpty ? nil : v
            }
        }
        if let r = header.range(of: "filename\\s*=\\s*[^;]+", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let eq = m.firstIndex(of: "=") {
                let v = String(m[m.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}
