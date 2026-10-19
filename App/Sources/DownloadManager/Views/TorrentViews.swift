import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Dosya seçimi (çok dosyalı torrentler)

final class TorrentFileChoice: ObservableObject {
    struct Row: Identifiable {
        let id: Int          // aria2 file index (1-based)
        let path: String     // path inside the torrent
        let length: Int64
    }
    let rows: [Row]
    @Published var selected: Set<Int>

    init(rows: [Row]) {
        self.rows = rows
        selected = Set(rows.map(\.id))
    }

    var selectedSize: Int64 { rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.length } }
}

struct TorrentFileListView: View {
    @ObservedObject var model: TorrentFileChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select All") { model.selected = Set(model.rows.map(\.id)) }
                Button("Select None") { model.selected = [] }
                Spacer()
                Text("\(model.selected.count) of \(model.rows.count) files · \(Fmt.size(model.selectedSize))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            List(model.rows) { row in
                Toggle(isOn: Binding(
                    get: { model.selected.contains(row.id) },
                    set: { on in if on { model.selected.insert(row.id) } else { model.selected.remove(row.id) } }
                )) {
                    HStack {
                        Text(row.path).lineLimit(1).truncationMode(.middle).help(row.path)
                        Spacer()
                        Text(Fmt.size(row.length)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
        }
        .padding(.top, 4)
    }
}

enum TorrentFilePicker {
    /// Shows the file list of a multi-file torrent. Returns the chosen aria2 file indexes (1-based),
    /// or nil when the user cancels or chooses nothing.
    static func run(torrentName: String, files: [TorrentEngine.TorrentFile], dir: String?) -> [Int]? {
        let prefix = ((dir ?? "") as NSString).appendingPathComponent(torrentName) + "/"
        let rows = files.map { f in
            TorrentFileChoice.Row(id: f.index,
                                  path: f.path.hasPrefix(prefix) ? String(f.path.dropFirst(prefix.count)) : (f.path as NSString).lastPathComponent,
                                  length: f.length)
        }
        let model = TorrentFileChoice(rows: rows)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Choose the files to download")
        alert.informativeText = torrentName
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        let height = min(CGFloat(rows.count) * 24 + 70, 380)
        let host = NSHostingView(rootView: TorrentFileListView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: height)
        alert.accessoryView = host
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !model.selected.isEmpty else { return nil }
        return model.selected.sorted()
    }
}

// MARK: - Varsayılan uygulama (magnet: ve .torrent)

enum TorrentDefaults {
    static let torrentType = UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent")

    /// Name of the app that currently opens magnet links / .torrent files.
    static func currentHandlers() -> (magnet: String?, file: String?) {
        let ws = NSWorkspace.shared
        func name(_ url: URL?) -> String? { url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } }
        let magnet = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000").flatMap { ws.urlForApplication(toOpen: $0) }
        let file = torrentType.flatMap { ws.urlForApplication(toOpen: $0) }
        return (name(magnet), name(file))
    }

    static var isDefault: Bool {
        let ws = NSWorkspace.shared
        let me = Bundle.main.bundleURL.standardizedFileURL
        let magnet = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000").flatMap { ws.urlForApplication(toOpen: $0) }
        let file = torrentType.flatMap { ws.urlForApplication(toOpen: $0) }
        return magnet?.standardizedFileURL == me && file?.standardizedFileURL == me
    }

    /// Makes this app the default for magnet links and .torrent files (macOS may ask the user to confirm).
    static func makeDefault(completion: @escaping (Error?) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { err in
            guard err == nil, let type = torrentType else { DispatchQueue.main.async { completion(err) }; return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { err2 in
                DispatchQueue.main.async { completion(err2) }
            }
        }
    }
}

// MARK: - Ayarlar ▸ Torrent

struct TorrentSettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var handlers = TorrentDefaults.currentHandlers()
    @State private var defaultError: String?

    var body: some View {
        Form {
            Section("aria2c") {
                if let path = TorrentEngine.locateAria2c() {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("aria2c not found. Install it with Homebrew: brew install aria2").foregroundStyle(.red)
                }
                Text("Torrents stop sharing (seeding) as soon as the download is complete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speed limit") {
                Toggle("Limit torrent download speed", isOn: $settings.torrentLimitEnabled)
                Stepper(value: $settings.torrentLimitKB, in: 64...102_400, step: 256) {
                    Text("Limit: \(Fmt.speed(Double(settings.torrentLimitKB) * 1024))")
                }
                .disabled(!settings.torrentLimitEnabled)
                Text("Applies immediately to running torrents. Also available from the menu bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Magnet links and .torrent files") {
                LabeledContent("Magnet links open with") { Text(handlers.magnet ?? "—") }
                LabeledContent(".torrent files open with") { Text(handlers.file ?? "—") }
                HStack {
                    Button("Use MC Download Manager") {
                        TorrentDefaults.makeDefault { err in
                            defaultError = err?.localizedDescription
                            handlers = TorrentDefaults.currentHandlers()
                        }
                    }
                    .disabled(TorrentDefaults.isDefault)
                    if let defaultError { Text(defaultError).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { handlers = TorrentDefaults.currentHandlers() }
    }
}
