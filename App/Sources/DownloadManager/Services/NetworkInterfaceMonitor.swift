import Foundation
import Network
import SystemConfiguration
import Darwin

enum NetworkInterfaceKind: String, Codable, CaseIterable {
    case wifi
    case ethernet
    case usb
    case vpn
    case bridge
    case other

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .usb: return "iphone"
        case .vpn: return "lock.shield"
        case .bridge: return "point.3.connected.trianglepath.dotted"
        case .other: return "network"
        }
    }

    var label: String {
        switch self {
        case .wifi: return String(localized: "Wi-Fi")
        case .ethernet: return String(localized: "Ethernet")
        case .usb: return String(localized: "USB / Hotspot")
        case .vpn: return String(localized: "VPN")
        case .bridge: return String(localized: "Bridge")
        case .other: return String(localized: "Network")
        }
    }

    /// Physical internet-capable interfaces included when automatic multi-network is enabled.
    var isAutoSelectable: Bool {
        switch self {
        case .wifi, .ethernet, .usb, .other: return true
        case .vpn, .bridge: return false
        }
    }
}

struct NetworkInterfaceInfo: Identifiable, Equatable, Hashable {
    var id: String { device }
    let device: String          // e.g. "en0", "en5", "en7"
    let displayName: String     // e.g. "Wi-Fi", "USB 10/100/1000 LAN", "iPhone USB"
    let kind: NetworkInterfaceKind
    let ipv4Address: String?
    let ipv6Address: String?
    let subnet: String?         // e.g. "192.168.1.0/24"

    var primaryAddress: String? { ipv4Address ?? ipv6Address }

    var shortLabel: String {
        displayName == device ? device : "\(displayName) (\(device))"
    }
}

/// Discovers active macOS network interfaces (Wi-Fi, Ethernet, iPhone USB, etc.)
/// and publishes updates whenever interfaces appear, disappear, or change IP.
final class NetworkInterfaceMonitor: ObservableObject {
    static let shared = NetworkInterfaceMonitor()

    @Published private(set) var interfaces: [NetworkInterfaceInfo] = []

    private let queue = DispatchQueue(label: "dm.network-monitor", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var cachedPortNames: (devices: String, names: [String: String])?

    private init() {
        interfaces = discoverInterfaces(allowSubprocess: false)

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.refresh()
        }
        pathMonitor.start(queue: queue)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t

        refresh()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let list = self.discoverInterfaces()
            DispatchQueue.main.async {
                if self.interfaces != list {
                    self.interfaces = list
                }
            }
        }
    }

    /// Interfaces to use for a download based on current settings.
    /// Returns an empty array when multi-network is disabled or fewer than 2 interfaces are selected
    /// (in which case the downloader uses the default OS route).
    func activeInterfacesForDownload(settings: AppSettings) -> [NetworkInterfaceInfo] {
        guard settings.multiNetworkEnabled else { return [] }
        if settings.multiNetworkAutoSelect {
            return interfaces.filter { $0.kind.isAutoSelectable }
        }
        let chosen = interfaces.filter { settings.selectedNetworkIDs.contains($0.id) }
        return chosen
    }

    /// Returns true if two or more of the given interfaces share the same IPv4 subnet (same router/LAN).
    static func hasSharedSubnet(_ list: [NetworkInterfaceInfo]) -> Bool {
        var seen = Set<String>()
        for iface in list {
            if let s = iface.subnet {
                if !seen.insert(s).inserted { return true }
            }
        }
        return false
    }

    // MARK: - Discovery

    private func discoverInterfaces(allowSubprocess: Bool = true) -> [NetworkInterfaceInfo] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        struct RawIface {
            var ipv4: String?
            var ipv6: String?
            var subnet: String?
        }

        var rawMap: [String: RawIface] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next

            let flags = Int32(ifa.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback, let addr = ifa.ifa_addr else { continue }

            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let device = String(cString: ifa.ifa_name)
            // Skip Apple internal peer-to-peer / AWDL / low-latency Wi-Fi / virtual control interfaces
            if device.hasPrefix("lo") || device.hasPrefix("awdl") || device.hasPrefix("llw")
                || device.hasPrefix("anpi") || device.hasPrefix("ap") || device.hasPrefix("gif")
                || device.hasPrefix("stf") || device.hasPrefix("XHC") {
                continue
            }

            guard let ip = numericAddress(addr) else { continue }

            if family == AF_INET {
                if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
                var entry = rawMap[device] ?? RawIface()
                if entry.ipv4 == nil {
                    entry.ipv4 = ip
                    if let maskAddr = ifa.ifa_netmask, let mask = numericAddress(maskAddr) {
                        entry.subnet = Self.ipv4Subnet(address: ip, netmask: mask)
                    }
                }
                rawMap[device] = entry
            } else if family == AF_INET6 {
                let cleanIP = ip.components(separatedBy: "%").first ?? ip
                let lower = cleanIP.lowercased()
                if lower == "::1" || lower.hasPrefix("fe80:") { continue }
                var entry = rawMap[device] ?? RawIface()
                if entry.ipv6 == nil { entry.ipv6 = cleanIP }
                rawMap[device] = entry
            }
        }

        let devices = rawMap.keys.sorted()
        guard !devices.isEmpty else { return [] }

        let scInfo = systemConfigInfo()
        let needsSubprocess = allowSubprocess && devices.contains { scInfo[$0] == nil }
        let portNames = needsSubprocess ? hardwarePortNames(for: devices) : [:]

        var result: [NetworkInterfaceInfo] = []
        for dev in devices {
            guard let raw = rawMap[dev] else { continue }
            let sc = scInfo[dev]
            let displayName = sc?.name ?? portNames[dev] ?? dev
            let kind = classify(device: dev, scType: sc?.type, displayName: displayName)
            result.append(NetworkInterfaceInfo(
                device: dev,
                displayName: displayName,
                kind: kind,
                ipv4Address: raw.ipv4,
                ipv6Address: raw.ipv6,
                subnet: raw.subnet
            ))
        }

        // Order: Ethernet -> Wi-Fi -> USB -> Other -> VPN -> Bridge, then by device name
        let priority: [NetworkInterfaceKind: Int] = [
            .ethernet: 0, .wifi: 1, .usb: 2, .other: 3, .vpn: 4, .bridge: 5
        ]
        return result.sorted {
            let p0 = priority[$0.kind] ?? 9
            let p1 = priority[$1.kind] ?? 9
            return p0 != p1 ? p0 < p1 : $0.device < $1.device
        }
    }

    private func numericAddress(_ addr: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.pointee.sa_len)
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: host)
    }

    private func systemConfigInfo() -> [String: (name: String, type: String)] {
        var map: [String: (String, String)] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return map }
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            let type = (SCNetworkInterfaceGetInterfaceType(iface) as String?) ?? ""
            map[bsd] = (name, type)
        }
        return map
    }

    private func hardwarePortNames(for devices: [String]) -> [String: String] {
        let key = devices.joined(separator: ",")
        if let cached = cachedPortNames, cached.devices == key {
            return cached.names
        }
        var names: [String: String] = [:]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                for block in text.components(separatedBy: "\n\n") {
                    let values = block
                        .split(separator: "\n")
                        .compactMap { line -> String? in
                            guard let idx = line.firstIndex(of: ":") else { return nil }
                            return line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                        }
                    if values.count >= 2 {
                        let port = values[0]
                        let dev = values[1]
                        if dev.range(of: "^[a-z]+[0-9]+$", options: .regularExpression) != nil {
                            names[dev] = port
                        }
                    }
                }
            }
        } catch {
            // networksetup unavailable — fall back to SCNetworkInterface / BSD names
        }
        cachedPortNames = (key, names)
        return names
    }

    private func classify(device: String, scType: String?, displayName: String) -> NetworkInterfaceKind {
        let lower = displayName.lowercased()
        let devLower = device.lowercased()

        if devLower.hasPrefix("utun") || devLower.hasPrefix("ppp") || devLower.hasPrefix("ipsec")
            || lower.contains("vpn") || lower.contains("wireguard") || lower.contains("tailscale") {
            return .vpn
        }
        if devLower.hasPrefix("bridge") || lower.contains("bridge") || scType == "Bridge" {
            return .bridge
        }
        if scType == (kSCNetworkInterfaceTypeIEEE80211 as String)
            || lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("wlan") || lower.contains("airport") {
            return .wifi
        }
        if lower.contains("iphone") || lower.contains("ipad") || lower.contains("android")
            || lower.contains("tether") || lower.contains("rndis") || lower.contains("hotspot")
            || lower.contains("cellular") || lower.contains("wwan") {
            return .usb
        }
        if scType == (kSCNetworkInterfaceTypeEthernet as String)
            || lower.contains("ethernet") || lower.contains("lan") || lower.contains("thunderbolt")
            || lower.contains("usb 10/") || lower.contains("gigabit") || lower.contains("2.5g") {
            return .ethernet
        }
        if lower.contains("usb") {
            return .usb
        }
        return .other
    }

    static func ipv4Subnet(address: String, netmask: String) -> String? {
        let ipParts = address.split(separator: ".").compactMap { UInt8($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }
        let net = zip(ipParts, maskParts).map { String($0 & $1) }.joined(separator: ".")
        let bits = maskParts.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(net)/\(bits)"
    }
}
