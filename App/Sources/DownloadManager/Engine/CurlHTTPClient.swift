import Foundation

struct CurlHTTPResponse {
    let statusCode: Int
    let headers: [String: String]   // lowercased keys
    let finalURL: URL

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var expectedContentLength: Int64 {
        header("content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1
    }
}

struct CurlError: LocalizedError {
    let code: Int32
    let message: String
    var isCancelled: Bool { code == mc_curl_code_aborted_by_callback() }
    var isInterfaceError: Bool { code == mc_curl_code_interface_failed() }
    var errorDescription: String? { message }
}

/// Performs a single HTTP/HTTPS streaming GET request pinned to a specific macOS network interface
/// (e.g. `en0`, `en5`, `en7`) using system `libcurl` (`CURLOPT_INTERFACE = "if!<device>"`).
/// Follows up to 5 redirects manually so credentials are stripped on cross-origin redirects.
final class CurlStreamTask {
    private static let workerQueue = DispatchQueue(label: "dm.curl-worker", qos: .userInitiated, attributes: .concurrent)
    private static let credentialHeaders: Set<String> = ["cookie", "authorization", "proxy-authorization"]
    private static let allowedSchemes: Set<String> = ["http", "https"]
    private static let maxRedirects = 5

    private static func isAllowedHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            return false
        }
        return url.host?.isEmpty == false
    }

    let id: Int
    private let initialURL: URL
    private let headers: [String: String]
    private let range: String?                  // e.g. "0-1048575" (without "bytes=")
    private let interfaceDevice: String?        // e.g. "en0"
    private let interfaceAddress: String?       // fallback local IP if "if!<dev>" fails
    private let ipv4Only: Bool                  // force IPv4 when interface has no IPv6
    private let originHost: String?
    private let originScheme: String?

    private let onHeaders: (CurlHTTPResponse) -> Bool
    private let onData: (Data) -> Bool
    private let onComplete: (Result<Void, Error>) -> Void

    private let lock = NSLock()
    private var _cancelled = false

    private static let idLock = NSLock()
    private static var nextID = 1
    private static func allocateID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let v = nextID
        nextID += 1
        return v
    }

    init(
        url: URL,
        headers: [String: String],
        range: String?,
        interfaceDevice: String?,
        interfaceAddress: String?,
        ipv4Only: Bool = false,
        originHost: String?,
        originScheme: String?,
        onHeaders: @escaping (CurlHTTPResponse) -> Bool,
        onData: @escaping (Data) -> Bool,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        self.id = Self.allocateID()
        self.initialURL = url
        self.headers = headers
        self.range = range
        self.interfaceDevice = interfaceDevice
        self.interfaceAddress = interfaceAddress
        self.ipv4Only = ipv4Only
        self.originHost = originHost?.lowercased()
        self.originScheme = originScheme?.lowercased()
        self.onHeaders = onHeaders
        self.onData = onData
        self.onComplete = onComplete
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    func start() {
        Self.workerQueue.async { [self] in
            self.run()
        }
    }

    private func sameOrigin(_ url: URL) -> Bool {
        guard let originHost, let originScheme else { return true }
        return url.host?.lowercased() == originHost && url.scheme?.lowercased() == originScheme
    }

    // Per-request mutable state passed as userdata to C callbacks.
    private final class TransferContext {
        let task: CurlStreamTask
        let currentURL: URL
        var statusCode: Int = 0
        var headers: [String: String] = [:]
        var headersDelivered = false
        var stoppedByCaller = false
        var redirectLocation: String?

        init(task: CurlStreamTask, currentURL: URL) {
            self.task = task
            self.currentURL = currentURL
        }
    }

    private func run() {
        var currentURL = initialURL
        guard Self.isAllowedHTTPURL(currentURL) else {
            onComplete(.failure(DownloadFailure(message: "Unsupported URL scheme")))
            return
        }
        var redirectsLeft = Self.maxRedirects
        var useAddressFallback = false

        while true {
            if isCancelled {
                onComplete(.failure(CurlError(code: mc_curl_code_aborted_by_callback(), message: "Cancelled")))
                return
            }

            guard let handle = mc_curl_easy_init() else {
                onComplete(.failure(DownloadFailure(message: "Could not initialize libcurl")))
                return
            }

            let ctx = TransferContext(task: self, currentURL: currentURL)
            let unmanaged = Unmanaged.passRetained(ctx)
            let userdata = unmanaged.toOpaque()

            var slist: UnsafeMutableRawPointer? = nil
            let allowCreds = sameOrigin(currentURL)
            for (k, v) in headers where allowCreds || !Self.credentialHeaders.contains(k.lowercased()) {
                let line = "\(k): \(v)"
                slist = line.withCString { mc_curl_slist_append(slist, $0) }
            }
            slist = "Accept-Encoding: identity".withCString { mc_curl_slist_append(slist, $0) }
            // Disable Expect: 100-continue overhead
            slist = "Expect:".withCString { mc_curl_slist_append(slist, $0) }

            _ = currentURL.absoluteString.withCString { mc_curl_setopt_url(handle, $0) }
            _ = mc_curl_setopt_httpheader(handle, slist)
            _ = mc_curl_setopt_followlocation(handle, 0) // manual redirects for same-origin credential safety
            if mc_curl_setopt_protocols_http_https(handle) != mc_curl_code_ok() {
                mc_curl_slist_free_all(slist)
                mc_curl_easy_cleanup(handle)
                unmanaged.release()
                onComplete(.failure(DownloadFailure(message: "Could not configure libcurl protocol allowlist")))
                return
            }
            _ = mc_curl_setopt_nosignal(handle, 1)
            if ipv4Only {
                _ = mc_curl_setopt_ipresolve(handle, 1) // CURL_IPRESOLVE_V4
            }
            _ = mc_curl_setopt_connecttimeout(handle, 15)
            _ = mc_curl_setopt_low_speed(handle, 1, 30)
            _ = mc_curl_setopt_tcp_keepalive(handle, 1)
            _ = mc_curl_setopt_buffersize(handle, 131_072)
            _ = mc_curl_setopt_noprogress(handle, 0)

            if let range {
                _ = range.withCString { mc_curl_setopt_range(handle, $0) }
            }

            if !useAddressFallback, let dev = interfaceDevice, !dev.isEmpty {
                let spec = "if!\(dev)"
                _ = spec.withCString { mc_curl_setopt_interface(handle, $0) }
            } else if let addr = interfaceAddress, !addr.isEmpty {
                _ = addr.withCString { mc_curl_setopt_interface(handle, $0) }
            }

            _ = mc_curl_setopt_header_cb(handle, Self.mcCurlHeaderCallback, userdata)
            _ = mc_curl_setopt_write_cb(handle, Self.mcCurlWriteCallback, userdata)
            _ = mc_curl_setopt_xferinfo_cb(handle, Self.mcCurlXferInfoCallback, userdata)

            let code = mc_curl_easy_perform(handle)

            mc_curl_slist_free_all(slist)
            mc_curl_easy_cleanup(handle)
            unmanaged.release()

            // If we got a 3xx redirect, follow it manually.
            if let loc = ctx.redirectLocation {
                guard redirectsLeft > 0 else {
                    onComplete(.failure(DownloadFailure(message: "Too many redirects")))
                    return
                }
                guard let nextURL = URL(string: loc, relativeTo: currentURL)?.absoluteURL,
                      Self.isAllowedHTTPURL(nextURL) else {
                    onComplete(.failure(DownloadFailure(message: "Blocked redirect to unsupported URL scheme")))
                    return
                }
                currentURL = nextURL
                redirectsLeft -= 1
                continue
            }

            // If "if!<device>" failed on an unusual virtual interface, retry once with its local IP address.
            if code == mc_curl_code_interface_failed(), !useAddressFallback,
               interfaceDevice != nil, interfaceAddress != nil {
                useAddressFallback = true
                continue
            }

            if isCancelled {
                onComplete(.failure(CurlError(code: mc_curl_code_aborted_by_callback(), message: "Cancelled")))
                return
            }

            if ctx.stoppedByCaller {
                // Caller intentionally returned false from onHeaders (e.g. probe) or onData (e.g. segment split).
                onComplete(.success(()))
                return
            }

            if code == mc_curl_code_ok() {
                // Ensure onHeaders was delivered even for header-less/empty responses.
                if !ctx.headersDelivered && ctx.statusCode > 0 {
                    let resp = CurlHTTPResponse(statusCode: ctx.statusCode, headers: ctx.headers, finalURL: currentURL)
                    _ = onHeaders(resp)
                }
                onComplete(.success(()))
                return
            }

            let msg = mc_curl_easy_strerror(code).map { String(cString: $0) } ?? "curl error \(code)"
            onComplete(.failure(CurlError(code: code, message: msg)))
            return
        }
    }

    // MARK: - C Callbacks

    private static let mcCurlHeaderCallback: mc_curl_write_cb = { ptr, size, nmemb, userdata in
        let total = size * nmemb
        guard let ptr, let userdata else { return 0 }
        let ctx = Unmanaged<TransferContext>.fromOpaque(userdata).takeUnretainedValue()
        if ctx.task.isCancelled { return 0 }

        let data = Data(bytes: ptr, count: total)
        guard let line = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) else {
            return total
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("HTTP/") {
            // New HTTP response block (e.g. after 100 Continue)
            ctx.headers.removeAll()
            let parts = trimmed.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                ctx.statusCode = code
            }
            return total
        }

        if trimmed.isEmpty {
            // End of headers for this response block.
            if ctx.statusCode == 100 || ctx.statusCode == 103 {
                // Informational 1xx: wait for the real status block.
                return total
            }
            if (300...399).contains(ctx.statusCode), let loc = ctx.headers["location"], !loc.isEmpty {
                ctx.redirectLocation = loc
                return 0 // stop reading redirect body; loop will follow Location
            }
            if !ctx.headersDelivered {
                ctx.headersDelivered = true
                let resp = CurlHTTPResponse(
                    statusCode: ctx.statusCode,
                    headers: ctx.headers,
                    finalURL: ctx.currentURL
                )
                if !ctx.task.onHeaders(resp) {
                    ctx.stoppedByCaller = true
                    return 0
                }
            }
            return total
        }

        if let colon = trimmed.firstIndex(of: ":") {
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            ctx.headers[key] = val
        }
        return total
    }

    private static let mcCurlWriteCallback: mc_curl_write_cb = { ptr, size, nmemb, userdata in
        let total = size * nmemb
        guard let ptr, let userdata else { return 0 }
        let ctx = Unmanaged<TransferContext>.fromOpaque(userdata).takeUnretainedValue()
        if ctx.task.isCancelled { return 0 }
        if total == 0 { return 0 }

        let data = Data(bytes: ptr, count: total)
        if !ctx.task.onData(data) {
            ctx.stoppedByCaller = true
            return 0
        }
        return total
    }

    private static let mcCurlXferInfoCallback: mc_curl_xferinfo_cb = { clientp, _, _, _, _ in
        guard let clientp else { return 0 }
        let ctx = Unmanaged<TransferContext>.fromOpaque(clientp).takeUnretainedValue()
        return ctx.task.isCancelled ? 1 : 0
    }
}
