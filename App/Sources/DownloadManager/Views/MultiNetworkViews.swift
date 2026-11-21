import SwiftUI
import AppKit

// MARK: - Network Color Palette

enum NetworkPalette {
    static let wifi = Color(red: 0.18, green: 0.78, blue: 0.56)      // Teal / Emerald
    static let usb = Color(red: 0.96, green: 0.62, blue: 0.18)       // Amber / Orange
    static let ethernet = Color(red: 0.32, green: 0.65, blue: 0.96)  // Steel / Cyan-Blue
    static let violet = Color(red: 0.68, green: 0.48, blue: 0.95)
    static let rose = Color(red: 0.95, green: 0.38, blue: 0.55)
    static let lime = Color(red: 0.58, green: 0.84, blue: 0.24)

    static func color(for name: String, kind: NetworkInterfaceKind? = nil) -> Color {
        if let kind {
            switch kind {
            case .wifi: return wifi
            case .usb: return usb
            case .ethernet: return ethernet
            case .vpn: return violet
            case .bridge, .other: break
            }
        }
        let lower = name.lowercased()
        if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("wlan") || lower.contains("airport") {
            return wifi
        }
        if lower.contains("iphone") || lower.contains("ipad") || lower.contains("usb") || lower.contains("hotspot") || lower.contains("android") || lower.contains("tether") {
            return usb
        }
        if lower.contains("ethernet") || lower.contains("lan") || lower.contains("thunderbolt") {
            return ethernet
        }
        if lower.contains("vpn") || lower.contains("utun") {
            return violet
        }
        let fallbacks = [ethernet, wifi, usb, violet, rose, lime]
        let hash = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return fallbacks[hash % fallbacks.count]
    }

    static func badgeLabel(for kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .wifi: return "WIFI"
        case .usb: return "USB"
        case .ethernet: return "ETH"
        case .vpn: return "VPN"
        case .bridge, .other: return "NET"
        }
    }
}

// MARK: - Network Summary Model for Detail View

struct NetworkStreamGroup: Identifiable {
    let id: String              // network displayName
    let name: String
    let color: Color
    let enabled: Bool
    let speed: Double
    let bytesDownloaded: Int64
    let share: Double           // 0...1
    let segments: [(index: Int, segment: SegmentInfo)]

    var activeStreamCount: Int {
        segments.filter { !$0.segment.isDone }.count
    }
}

extension DownloadItem {
    func networkStreamGroups(settings: AppSettings) -> [NetworkStreamGroup] {
        var names = Set<String>()
        for k in networkSpeeds.keys { names.insert(k) }
        for k in networkBytes.keys { names.insert(k) }
        for s in segments { if let n = s.interfaceName { names.insert(n) } }
        for n in disabledNetworks { names.insert(n) }

        if names.isEmpty {
            let active = NetworkInterfaceMonitor.shared.activeInterfacesForDownload(settings: settings)
            for iface in active { names.insert(iface.displayName) }
        }
        if names.isEmpty {
            names.insert(String(localized: "Default"))
        }

        // Order consistently: Wi-Fi first, then USB, then Ethernet, then alphabetical
        let sortedNames = names.sorted { a, b in
            let pa = priority(of: a)
            let pb = priority(of: b)
            return pa != pb ? pa < pb : a < b
        }

        let totalNetBytes = max(1, sortedNames.reduce(Int64(0)) { sum, name in
            sum + networkBytesFor(name: name)
        })

        return sortedNames.map { name in
            let segs = segments.enumerated().filter { ($0.element.interfaceName ?? String(localized: "Default")) == name }
            let bytes = networkBytesFor(name: name)
            let spd = disabledNetworks.contains(name) ? 0 : (networkSpeeds[name] ?? 0)
            let enabled = !disabledNetworks.contains(name)
            let share = totalNetBytes > 0 ? Double(bytes) / Double(totalNetBytes) : 0
            return NetworkStreamGroup(
                id: name,
                name: name,
                color: NetworkPalette.color(for: name),
                enabled: enabled,
                speed: spd,
                bytesDownloaded: bytes,
                share: share,
                segments: segs.map { ($0.offset, $0.element) }
            )
        }
    }

    private func networkBytesFor(name: String) -> Int64 {
        if let b = networkBytes[name], b > 0 { return b }
        let segSum = segments
            .filter { ($0.interfaceName ?? String(localized: "Default")) == name }
            .reduce(Int64(0)) { $0 + $1.received }
        return segSum
    }

    private func priority(of name: String) -> Int {
        let l = name.lowercased()
        if l.contains("wi-fi") || l.contains("wifi") { return 0 }
        if l.contains("iphone") || l.contains("usb") || l.contains("hotspot") { return 1 }
        if l.contains("ethernet") || l.contains("lan") { return 2 }
        return 3
    }
}

// MARK: - 1. Hero Band (Merge Diagram + Big Speed & Multiplier Chip + Throughput Chart)

struct MultiNetworkHeroView: View {
    let item: DownloadItem
    let groups: [NetworkStreamGroup]
    @State private var chipIndex = 0

    private var isPaused: Bool { item.state != .downloading }

    private var avgSpeed: Double {
        guard let started = item.startedAt else { return item.speed }
        let elapsed = max(1, Date().timeIntervalSince(started))
        return Double(item.receivedBytes) / elapsed
    }

    private var multiplierChips: [(label: String, color: Color, tooltip: String)] {
        let activeGroups = groups.filter { $0.speed > 0 || $0.bytesDownloaded > 0 }
        guard activeGroups.count >= 2 else { return [] }
        let useSpeed = item.speed > 0 && !isPaused
        let totalMetric = useSpeed ? item.speed : Double(item.receivedBytes)
        guard totalMetric > 0 else { return [] }

        return activeGroups.compactMap { g -> (Double, String, Color, String)? in
            let metric = useSpeed ? g.speed : Double(g.bytesDownloaded)
            guard metric > 0 else { return nil }
            let ratio = totalMetric / metric
            guard ratio >= 1.05, ratio < 50 else { return nil }
            let ratioStr = String(format: "%.1f", ratio)
            let netUpper = g.name.uppercased()
            let label = String(localized: "\(ratioStr)× \(netUpper) ALONE")
            let tip = String(localized: "\(ratioStr)× faster than \(g.name) alone")
            return (ratio, label, g.color, tip)
        }
        .sorted { $0.0 < $1.0 }
        .map { ($0.1, $0.2, $0.3) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            NetworkMergeDiagramView(groups: groups, isPaused: isPaused)
                .frame(width: 195, height: max(76, CGFloat(max(groups.count, 1)) * 36))

            // Headline TOTAL SPEED + AVG/PEAK + Multiplier Chip
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(localized: "TOTAL SPEED"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    let mergedCount = groups.filter { $0.enabled }.count
                    if mergedCount >= 2 {
                        Text(String(localized: "· \(mergedCount) MERGED"))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(NetworkPalette.wifi)
                    }
                }

                Text(isPaused ? "—" : Fmt.speed(item.speed))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    Text(String(localized: "AVG"))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(avgSpeed > 0 ? Fmt.speed(avgSpeed) : "—")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(localized: "PEAK"))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.peakSpeed > 0 ? Fmt.speed(item.peakSpeed) : "—")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }

                let chips = multiplierChips
                if !chips.isEmpty {
                    let current = chips[chipIndex % chips.count]
                    Button {
                        chipIndex = (chipIndex + 1) % max(1, chips.count)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(current.color).frame(width: 6, height: 6)
                            Text(current.label)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(current.color.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(current.color.opacity(0.45), lineWidth: 0.8))
                        .foregroundStyle(current.color)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(current.tooltip)
                }
            }
            .frame(minWidth: 155, alignment: .leading)

            // Stacked Area Throughput Chart
            NetworkThroughputChartView(groups: groups, history: item.speedHistory, isPaused: isPaused)
                .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 92)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Merge Diagram (Animated Bezier Curves Merging into One Stream)

struct NetworkMergeDiagramView: View {
    let groups: [NetworkStreamGroup]
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isPaused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let count = max(1, groups.count)
                let midY = size.height / 2
                let labelX: CGFloat = 68
                let dotX: CGFloat = labelX + 8
                let curveStartX: CGFloat = dotX + 5
                let combineX: CGFloat = curveStartX + 64
                let streamEndX: CGFloat = size.width - 10

                let totalSpeed = max(1, groups.reduce(0.0) { $0 + $1.speed })

                for (idx, g) in groups.enumerated() {
                    let rowY = (CGFloat(idx) + 0.5) * (size.height / CGFloat(count))
                    let active = !isPaused && g.enabled && g.speed > 0
                    let share = active ? (g.speed / totalSpeed) : 0

                    // Label & Speed on the left
                    let title = Text(g.name.uppercased().prefix(11))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    ctx.draw(title, at: CGPoint(x: labelX, y: rowY - 6), anchor: .trailing)

                    let spdStr = g.speed > 0 && !isPaused ? Fmt.speed(g.speed) : (g.enabled ? "0 KB/s" : String(localized: "OFF"))
                    let spdText = Text(spdStr)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(active ? g.color : .secondary)
                    ctx.draw(spdText, at: CGPoint(x: labelX, y: rowY + 6), anchor: .trailing)

                    // Network Dot
                    let dotRect = CGRect(x: dotX - 3.5, y: rowY - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: dotRect), with: .color(g.enabled ? g.color : .gray.opacity(0.4)))

                    // Bezier curve from network dot to combine node
                    var curve = Path()
                    curve.move(to: CGPoint(x: curveStartX, y: rowY))
                    curve.addCurve(
                        to: CGPoint(x: combineX, y: midY),
                        control1: CGPoint(x: curveStartX + 34, y: rowY),
                        control2: CGPoint(x: combineX - 26, y: midY)
                    )

                    let lineWidth: CGFloat = active ? (1.8 + CGFloat(share) * 2.2) : 1.5
                    let opacity: Double = active ? (0.6 + share * 0.4) : 0.25
                    let dashSpeed: CGFloat = active ? (14.0 + CGFloat(share) * 28.0) : 0
                    let phase = -CGFloat(t) * dashSpeed

                    ctx.stroke(
                        curve,
                        with: .color(g.color.opacity(opacity)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [5, 7], dashPhase: phase)
                    )
                }

                // Combined thick output line + arrow
                let anyActive = !isPaused && groups.contains { $0.enabled && $0.speed > 0 }
                let outColor: Color = anyActive ? .primary : .secondary.opacity(0.4)

                var outLine = Path()
                outLine.move(to: CGPoint(x: combineX, y: midY))
                outLine.addLine(to: CGPoint(x: streamEndX - 4, y: midY))
                ctx.stroke(outLine, with: .color(outColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))

                var arrow = Path()
                arrow.move(to: CGPoint(x: streamEndX - 5, y: midY - 4.5))
                arrow.addLine(to: CGPoint(x: streamEndX + 2, y: midY))
                arrow.addLine(to: CGPoint(x: streamEndX - 5, y: midY + 4.5))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(outColor))

                // Combine node (outer halo + inner dot)
                let haloRect = CGRect(x: combineX - 8, y: midY - 8, width: 16, height: 16)
                ctx.stroke(Path(ellipseIn: haloRect), with: .color(outColor.opacity(0.35)), lineWidth: 1.5)
                let coreRect = CGRect(x: combineX - 3.5, y: midY - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: coreRect), with: .color(outColor))

                let mergedLabel = Text(isPaused ? String(localized: "PAUSED") : String(localized: "MERGED"))
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                ctx.draw(mergedLabel, at: CGPoint(x: (combineX + streamEndX) / 2, y: midY - 10), anchor: .center)
            }
        }
    }
}

// MARK: - Stacked Area Throughput Chart

struct NetworkThroughputChartView: View {
    let groups: [NetworkStreamGroup]
    let history: [[String: Double]]
    let isPaused: Bool
    @State private var hoverFraction: CGFloat? = nil

    private let maxSamples = 60

    private var peakTotal: Double {
        let m = history.map { sample in groups.reduce(0.0) { $0 + (sample[$1.name] ?? 0) } }.max() ?? 0
        return max(m, 1024 * 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "THROUGHPUT · LAST 30S"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let f = hoverFraction, !history.isEmpty {
                    let slot = Int(round(f * CGFloat(maxSamples - 1)))
                    let firstSlot = maxSamples - history.count
                    let idx = slot - firstSlot
                    if idx >= 0 && idx < history.count {
                        let sample = history[idx]
                        let tot = groups.reduce(0.0) { $0 + (sample[$1.name] ?? 0) }
                        Text(Fmt.speed(tot))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let top = peakTotal * 1.1
                        // Horizontal grid lines
                        for frac in [0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                            let y = size.height * (1 - frac)
                            var line = Path()
                            line.move(to: CGPoint(x: 0, y: y))
                            line.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.7)
                        }

                        guard history.count >= 2 else { return }
                        let xStep = size.width / CGFloat(maxSamples - 1)
                        let firstSlot = maxSamples - history.count
                        let firstX = CGFloat(firstSlot) * xStep
                        let toY: (Double) -> CGFloat = { val in
                            size.height - CGFloat(min(1.0, max(0.0, val / top))) * size.height
                        }

                        var cumulative = [Double](repeating: 0, count: history.count)

                        for g in groups {
                            let bottom = cumulative
                            var topVals = [Double](repeating: 0, count: history.count)
                            for i in 0..<history.count {
                                topVals[i] = bottom[i] + (history[i][g.name] ?? 0)
                            }
                            cumulative = topVals

                            var area = Path()
                            for i in 0..<history.count {
                                let pt = CGPoint(x: firstX + CGFloat(i) * xStep, y: toY(topVals[i]))
                                if i == 0 { area.move(to: pt) } else { area.addLine(to: pt) }
                            }
                            for i in (0..<history.count).reversed() {
                                let pt = CGPoint(x: firstX + CGFloat(i) * xStep, y: toY(bottom[i]))
                                area.addLine(to: pt)
                            }
                            area.closeSubpath()
                            ctx.fill(area, with: .color(g.color.opacity(isPaused ? 0.35 : 0.62)))
                        }

                        // Top outline of combined throughput
                        var outline = Path()
                        for i in 0..<history.count {
                            let pt = CGPoint(x: firstX + CGFloat(i) * xStep, y: toY(cumulative[i]))
                            if i == 0 { outline.move(to: pt) } else { outline.addLine(to: pt) }
                        }
                        ctx.stroke(outline, with: .color(.primary.opacity(0.8)), lineWidth: 1.6)

                        if let f = hoverFraction {
                            let hx = f * size.width
                            var vline = Path()
                            vline.move(to: CGPoint(x: hx, y: 0))
                            vline.addLine(to: CGPoint(x: hx, y: size.height))
                            ctx.stroke(vline, with: .color(.primary.opacity(0.45)), lineWidth: 1)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverFraction = min(1, max(0, loc.x / max(1, geo.size.width)))
                    case .ended:
                        hoverFraction = nil
                    }
                }
            }
        }
    }
}

// MARK: - 2. Color-Coded Chunk Grid & Legend

struct NetworkChunkGridView: View {
    let item: DownloadItem
    let groups: [NetworkStreamGroup]
    @State private var hoveredIndex: Int? = nil

    private var hoveredText: String {
        if let idx = hoveredIndex, idx < item.segments.count {
            let seg = item.segments[idx]
            let net = seg.interfaceName ?? String(localized: "Default")
            let chunkNum = idx + 1
            let recStr = Fmt.size(seg.received)
            let lenStr = Fmt.size(seg.length)
            return String(localized: "Chunk #\(chunkNum) · \(recStr) / \(lenStr) · \(net)")
        }
        if !item.segments.isEmpty {
            let totalCount = item.segments.count
            let doneCount = item.segments.filter(\.isDone).count
            return String(localized: "\(totalCount) chunks (\(doneCount) completed)")
        }
        return item.totalBytes > 0 ? Fmt.size(item.totalBytes) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(groups) { g in
                    HStack(spacing: 5) {
                        Circle().fill(g.color).frame(width: 7, height: 7)
                        Text(g.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(g.enabled ? .primary : .secondary)
                    }
                }
                Spacer()
                Text(hoveredText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if item.segments.count > 1 {
                let cols = Array(repeating: GridItem(.flexible(minimum: 14), spacing: 4), count: min(max(item.segments.count, 8), 16))
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { idx, seg in
                        let netName = seg.interfaceName ?? String(localized: "Default")
                        let color = NetworkPalette.color(for: netName)
                        let ratio = seg.length > 0 ? min(1.0, max(0.0, Double(seg.received) / Double(seg.length))) : 0
                        let isActive = item.state == .downloading && !seg.isDone && seg.received > 0

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.18))
                                if ratio > 0 {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(color)
                                        .frame(width: max(3, geo.size.width * ratio))
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(
                                        hoveredIndex == idx ? Color.primary : (isActive ? color : Color.secondary.opacity(0.25)),
                                        lineWidth: hoveredIndex == idx ? 1.4 : (isActive ? 1.0 : 0.5)
                                    )
                            )
                            .shadow(color: isActive ? color.opacity(0.45) : .clear, radius: 3)
                        }
                        .frame(height: 14)
                        .onHover { inside in
                            if inside { hoveredIndex = idx }
                            else if hoveredIndex == idx { hoveredIndex = nil }
                        }
                    }
                }
            } else {
                SegmentBar(segments: item.segments, total: item.totalBytes, fallback: item.progress,
                           tint: item.state == .paused ? .secondary : .accentColor)
                    .frame(height: 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 3. Expandable Per-Network Table (NetworkRow + Stream Sub-rows)

struct NetworkStreamTableView: View {
    let item: DownloadItem
    let groups: [NetworkStreamGroup]
    @EnvironmentObject var store: DownloadStore
    @State private var expandedNetworks: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 10) {
                Text(String(localized: "NETWORK"))
                    .frame(minWidth: 215, alignment: .leading)
                Text(String(localized: "PROGRESS"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(localized: "SHARE"))
                    .frame(width: 48, alignment: .trailing)
                Text(String(localized: "SPEED"))
                    .frame(width: 88, alignment: .trailing)
                Text(String(localized: "DOWNLOADED"))
                    .frame(width: 112, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups) { g in
                        networkRow(g)
                        Divider().opacity(0.5)
                        if expandedNetworks.contains(g.id) {
                            ForEach(Array(g.segments.enumerated()), id: \.element.index) { streamIdx, entry in
                                streamSubRow(group: g, streamNumber: streamIdx + 1, chunkIndex: entry.index, seg: entry.segment)
                                Divider().opacity(0.25)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 155, maxHeight: 230)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func networkRow(_ g: NetworkStreamGroup) -> some View {
        let isExpanded = expandedNetworks.contains(g.id)
        let active = item.state == .downloading && g.enabled && g.speed > 0
        let pct = item.totalBytes > 0 ? min(1.0, Double(g.bytesDownloaded) / Double(item.totalBytes)) : g.share
        let sharePct = Int(round(g.share * 100))

        return HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(g.enabled ? g.color : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .shadow(color: active ? g.color.opacity(0.7) : .clear, radius: 4)

                Toggle("", isOn: Binding(
                    get: { g.enabled },
                    set: { on in store.setDownloadNetwork(id: item.id, networkName: g.name, enabled: on) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(String(localized: "Enable or disable \(g.name) for this download"))

                Text(g.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(g.enabled ? .primary : .secondary)
                    .lineLimit(1)

                if !g.segments.isEmpty {
                    let streamCount = g.segments.count
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded { expandedNetworks.remove(g.id) }
                            else { expandedNetworks.insert(g.id) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(String(localized: "\(streamCount) streams"))
                                .lineLimit(1)
                            Text(isExpanded ? "▲" : "▼").font(.system(size: 8))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 215, alignment: .leading)

            // Colored progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(g.color)
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(height: 6)
            .frame(maxWidth: .infinity)

            Text(g.bytesDownloaded == 0 ? "0%" : (sharePct == 0 ? "<1%" : "\(sharePct)%"))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Text(active ? Fmt.speed(g.speed) : (g.enabled ? "—" : String(localized: "Off")))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? g.color : .secondary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            Text(Fmt.size(g.bytesDownloaded))
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !g.segments.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedNetworks.remove(g.id) }
                else { expandedNetworks.insert(g.id) }
            }
        }
    }

    private func streamSubRow(group g: NetworkStreamGroup, streamNumber: Int, chunkIndex: Int, seg: SegmentInfo) -> some View {
        let ratio = seg.length > 0 ? min(1.0, max(0.0, Double(seg.received) / Double(seg.length))) : 0
        let pct = Int(round(ratio * 100))
        let isActive = item.state == .downloading && !seg.isDone && g.enabled
        let activeCount = max(1, g.activeStreamCount)
        let estStreamSpeed = isActive ? (g.speed / Double(activeCount)) : 0

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive || seg.isDone ? g.color : Color.gray.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .padding(.leading, 14)

                let chunkNum = chunkIndex + 1
                Text(String(localized: "Stream #\(streamNumber)"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))

                Text(String(localized: "Chunk #\(chunkNum)"))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                if seg.isDone {
                    Text(String(localized: "DONE"))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(g.color)
                } else if isActive {
                    Text(String(localized: "ACTIVE"))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(g.color.opacity(0.16))
                        .foregroundStyle(g.color)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(minWidth: 215, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule()
                        .fill(g.color)
                        .frame(width: max(0, geo.size.width * ratio))
                }
            }
            .frame(height: 5)
            .frame(maxWidth: .infinity)

            Text("\(pct)%")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Text(isActive && estStreamSpeed > 0 ? Fmt.speed(estStreamSpeed) : "—")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? g.color : .secondary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            Text("\(Fmt.size(seg.received)) / \(Fmt.size(seg.length))")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }
}
