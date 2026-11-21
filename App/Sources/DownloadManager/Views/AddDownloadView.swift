import SwiftUI
import AppKit

struct AddDownloadView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = NetworkInterfaceMonitor.shared

    @State private var text = ""
    @State private var asVideo = false
    @State private var streamsPerNetwork = 0    // 0 = Auto (settings.segmentCount), else 1, 2, 4, 8
    @State private var customDirectory: String = ""
    @State private var deselectedNetworkIDs: Set<String> = []

    private let streamOptions = [0, 1, 2, 4, 8]

    private var candidateInterfaces: [NetworkInterfaceInfo] {
        let physical = monitor.interfaces.filter { $0.kind.isAutoSelectable }
        return physical.isEmpty ? monitor.interfaces : physical
    }

    private var selectedInterfaces: [NetworkInterfaceInfo] {
        candidateInterfaces.filter { !deselectedNetworkIDs.contains($0.id) }
    }

    private var totalStreams: Int {
        let netCount = max(1, selectedInterfaces.count)
        if streamsPerNetwork == 0 {
            return max(settings.segmentCount, netCount * 2)
        }
        return min(16, max(1, streamsPerNetwork * netCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New Download").font(.title2.bold())
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s }
                } label: {
                    Label("PASTE ⌘V", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("LINK (ONE URL PER LINE)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 82)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            // SAVE TO
            HStack(spacing: 10) {
                Text("SAVE TO")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(customDirectory.isEmpty ? settings.downloadDirectory : customDirectory)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Browse…") { chooseFolder() }
                    .controlSize(.small)
            }

            Toggle("Download video from page (yt-dlp)", isOn: $asVideo)

            if !asVideo {
                Divider()

                // PARALLEL STREAMS selector (1x / 2x / 4x / 8x)
                HStack(spacing: 10) {
                    Text("PARALLEL STREAMS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        ForEach(streamOptions, id: \.self) { opt in
                            let isSelected = streamsPerNetwork == opt
                            Button {
                                streamsPerNetwork = opt
                            } label: {
                                Text(opt == 0 ? String(localized: "Auto") : "\(opt)×")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                                    )
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    let perNet = streamsPerNetwork == 0 ? max(1, totalStreams / max(1, selectedInterfaces.count)) : streamsPerNetwork
                    let totStr = totalStreams
                    Text(String(localized: "\(perNet) / network  ·  \(totStr) total parallel streams"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // NETWORKS Cards with Live Ping
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "NETWORKS"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        let detCount = candidateInterfaces.count
                        let selCount = selectedInterfaces.count
                        Text(String(localized: "\(detCount) detected  ·  \(selCount) selected"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    let cols = Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: min(max(candidateInterfaces.count, 1), 3))
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(candidateInterfaces) { iface in
                            networkCard(iface)
                        }
                    }
                }
            }

            Divider()

            HStack {
                let selCount = selectedInterfaces.count
                let totStr = totalStreams
                Text(String(localized: "\(selCount) networks selected  ·  \(totStr) parallel streams"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    let dir = customDirectory.isEmpty ? nil : URL(fileURLWithPath: customDirectory)
                    let allowed = Set(selectedInterfaces.map(\.id))
                    store.addURLs(
                        text,
                        kind: asVideo ? .video : .file,
                        segments: totalStreams,
                        directory: dir,
                        allowedNetworkIDs: allowed.isEmpty ? nil : allowed
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            customDirectory = settings.downloadDirectory
            monitor.refresh()
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http"), !s.contains("\n") {
                text = s
            }
        }
    }

    private func networkCard(_ iface: NetworkInterfaceInfo) -> some View {
        let selected = !deselectedNetworkIDs.contains(iface.id)
        let color = NetworkPalette.color(for: iface.displayName, kind: iface.kind)
        let ping = monitor.pingMs[iface.device]

        return Button {
            if selected {
                // Keep at least 1 network selected
                if selectedInterfaces.count > 1 {
                    deselectedNetworkIDs.insert(iface.id)
                }
            } else {
                deselectedNetworkIDs.remove(iface.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? color : .secondary)
                        .font(.system(size: 13))
                    Text(iface.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(NetworkPalette.badgeLabel(for: iface.kind))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(iface.device)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let ip = iface.ipv4Address ?? iface.ipv6Address {
                        Text(ip)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PING")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(ping != nil ? "\(ping!) ms" : "—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? color.opacity(0.11) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? color.opacity(0.55) : Color.secondary.opacity(0.22), lineWidth: selected ? 1.2 : 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: customDirectory.isEmpty ? settings.downloadDirectory : customDirectory)
        if p.runModal() == .OK, let u = p.url {
            customDirectory = u.path
        }
    }
}
