import SwiftUI
import AppKit

/// Dosya özelinde indirme penceresi (IDM tarzı): durum bilgileri, parça çubuğu ve bağlantı tablosu.
/// İndirme bitince "tamamlandı" görünümüne dönüşür.
struct DownloadDetailView: View {
    let id: UUID
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @State private var showDetails = true

    private var item: DownloadItem? { store.items.first { $0.id == id } }

    var body: some View {
        if let item {
            Group {
                if item.state == .completed {
                    completedView(item)
                } else {
                    activeView(item)
                }
            }
            .padding(16)
            .frame(minWidth: 520, idealWidth: 560)
        } else {
            Text("This download was removed from the list.").padding()
        }
    }

    // MARK: - İndirme sürerken

    private func activeView(_ item: DownloadItem) -> some View {
        VStack(spacing: 14) {
            infoGrid(item)
            ProgressView(value: item.totalBytes > 0 ? item.progress : 0)
                .progressViewStyle(.linear)
            HStack(spacing: 12) {
                Button(showDetails ? "<< Hide Details" : "Show Details >>") {
                    withAnimation { showDetails.toggle() }
                    DetailWindowManager.shared.resize(id: id, compact: !showDetails)
                }
                Toggle("Close when completed", isOn: $settings.autoCloseDetail)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                switch item.state {
                case .queued:
                    // Added while "Start new downloads immediately" is off, or waiting for a free slot.
                    Button("Start Download") { store.start(item.id) }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { store.cancel(item.id) }
                case .downloading, .probing:
                    Button("Pause") { store.pause(item.id) }
                    Button("Cancel") { store.cancel(item.id) }
                case .paused, .failed, .cancelled:
                    if item.state == .failed, item.kind == .file {
                        Button("Download in Browser") { store.handOffToBrowser(item.id); DetailWindowManager.shared.close(id: item.id) }
                    }
                    Button("Resume") { store.resume(item.id) }.keyboardShortcut(.defaultAction)
                    Button("Remove from List") { store.remove(item.id); DetailWindowManager.shared.close(id: item.id) }
                case .completed:
                    EmptyView()
                }
            }
            if showDetails {
                Divider()
                if item.kind != .file {
                    logView(item)
                } else {
                    connections(item)
                }
            }
        }
    }

    private func infoGrid(_ item: DownloadItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("URL").foregroundStyle(.secondary)
                Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(statusText(item)).foregroundStyle(item.state == .failed ? .red : .primary)
            }
            GridRow {
                Text("File size").foregroundStyle(.secondary)
                Text(item.totalBytes > 0 ? Fmt.size(item.totalBytes) : String(localized: "Unknown"))
            }
            GridRow {
                Text("Downloaded").foregroundStyle(.secondary)
                Text(item.totalBytes > 0
                     ? "\(Fmt.size(item.receivedBytes))  (\(Int(item.progress * 100))%)"
                     : Fmt.size(item.receivedBytes))
            }
            GridRow {
                Text("Transfer rate").foregroundStyle(.secondary)
                Text(item.state == .downloading ? Fmt.speed(item.speed) : "—")
            }
            GridRow {
                Text("Time left").foregroundStyle(.secondary)
                Text(item.eta.map(Fmt.duration) ?? "—")
            }
            GridRow {
                Text("Resume capability").foregroundStyle(.secondary)
                Text(item.kind != .file ? "yt-dlp" : (item.supportsRanges ? String(localized: "Yes") : (item.state == .queued || item.state == .probing ? "?" : String(localized: "No"))))
            }
            GridRow {
                Text("Save to").foregroundStyle(.secondary)
                Text(item.finalPath ?? store.destinationURL(for: item).path).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ item: DownloadItem) -> String {
        switch item.state {
        case .downloading:
            if item.kind != .file { return item.stage.isEmpty ? String(localized: "Downloading with yt-dlp…") : item.stage }
            return String(localized: "Receiving data…")
        case .failed: return item.errorMessage ?? String(localized: "Error")
        default: return item.state.label
        }
    }

    // MARK: - Tamamlandı görünümü

    private func completedView(_ item: DownloadItem) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download completed").font(.title2.bold())
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(Fmt.size(item.totalBytes))
                }
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Text(item.finalPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? store.destinationDirectory(for: item).path)
                        .lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("URL").foregroundStyle(.secondary)
                    Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let d = item.completedAt {
                    GridRow {
                        Text("Finished").foregroundStyle(.secondary)
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Close") { DetailWindowManager.shared.close(id: item.id) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Show in Finder") { store.revealInFinder(item); DetailWindowManager.shared.closeIfAlone(id: item.id) }
                Button("Open") { store.open(item); DetailWindowManager.shared.close(id: item.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bağlantı tablosu

    private func connections(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start positions and download progress by connections")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            SegmentBar(segments: item.segments, total: item.totalBytes, fallback: item.progress,
                       tint: item.state == .paused ? .secondary : .accentColor)
                .frame(height: 12)
            Table(connectionRows(item)) {
                TableColumn("N.") { Text("\($0.index)") }.width(36)
                TableColumn("Downloaded") { Text(Fmt.size($0.received)) }.width(110)
                TableColumn("Start") { Text(Fmt.size($0.start)) }.width(110)
                TableColumn("Info") { Text($0.info) }
            }
            .font(.callout.monospacedDigit())
            .frame(minHeight: 160)
        }
    }

    private struct ConnRow: Identifiable {
        let id: Int
        var index: Int { id + 1 }
        let received: Int64
        let start: Int64
        let info: String
    }

    private func connectionRows(_ item: DownloadItem) -> [ConnRow] {
        if item.segments.isEmpty {
            guard item.state != .queued else { return [] }
            let info: String
            switch item.state {
            case .probing: info = String(localized: "Sending GET…")
            case .downloading: info = String(localized: "Receiving data… (single stream)")
            case .paused: info = String(localized: "Paused")
            default: info = item.state.label
            }
            return [ConnRow(id: 0, received: item.receivedBytes, start: 0, info: info)]
        }
        return item.segments.enumerated().map { i, s in
            let info: String
            if s.isDone { info = String(localized: "Completed") }
            else if item.state == .downloading { info = s.received == 0 ? String(localized: "Sending GET…") : String(localized: "Receiving data…") }
            else if item.state == .paused { info = String(localized: "Paused") }
            else { info = item.state.label }
            return ConnRow(id: i, received: s.received, start: s.start, info: info)
        }
    }

    private func logView(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("yt-dlp output").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(item.log.isEmpty ? String(localized: "Waiting…") : item.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .onChange(of: item.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}

/// Downloads shown in the shared download window, and which one is selected.
final class DownloadPanelModel: ObservableObject {
    @Published var tracked: [UUID] = []
    @Published var selected: UUID?
}

/// The download window: one download's details, plus a list on the left while it tracks several downloads.
struct DownloadPanelView: View {
    @ObservedObject var model: DownloadPanelModel
    @EnvironmentObject var store: DownloadStore

    var body: some View {
        if model.tracked.count > 1 {
            HStack(spacing: 0) {
                List(selection: $model.selected) {
                    ForEach(model.tracked, id: \.self) { id in
                        if let item = store.items.first(where: { $0.id == id }) {
                            PanelRow(item: item).tag(id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: DetailWindowManager.listWidth)
                Divider()
                detail
            }
        } else {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selected ?? model.tracked.first {
            DownloadDetailView(id: id)
                .id(id)   // fresh state (details toggle) for each download
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct PanelRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.state == .completed ? "checkmark.circle.fill" : item.category.symbol)
                .foregroundStyle(item.state == .completed ? .green : item.state == .failed ? .red : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                if item.state.isActive || item.state == .paused {
                    ProgressView(value: item.totalBytes > 0 ? item.progress : 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        switch item.state {
        case .downloading:
            let pct = item.totalBytes > 0 ? "\(Int(item.progress * 100))%" : Fmt.size(item.receivedBytes)
            return item.speed > 0 ? "\(pct) · \(Fmt.speed(item.speed))" : pct
        case .completed: return Fmt.size(item.totalBytes)
        default: return item.state.label
        }
    }
}

/// The shared download window, managed with AppKit so it can open from anywhere
/// (for example on a request from the browser) without a SwiftUI scene.
final class DetailWindowManager {
    static let shared = DetailWindowManager()
    private var window: NSWindow?
    private var observer: Any?
    private let model = DownloadPanelModel()
    private var compact = false

    static let fullHeight: CGFloat = 540
    static let compactHeight: CGFloat = 290
    static let completedHeight: CGFloat = 250
    static let detailWidth: CGFloat = 560
    static let listWidth: CGFloat = 230

    private var showsList: Bool { model.tracked.count > 1 }

    func show(id: UUID, store: DownloadStore) {
        AppPresence.shared.showInDock()
        let hadList = showsList
        if !model.tracked.contains(id) { model.tracked.append(id) }
        model.selected = id
        if let w = window {
            if showsList != hadList { layout(store: store, animate: true) }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = DownloadPanelView(model: model)
            .environmentObject(store)
            .environmentObject(store.settings)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.detailWidth, height: Self.fullHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        window = w
        compact = false
        layout(store: store, animate: false)
        w.center()
        refreshTitles(items: store.items)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.window = nil
            self.model.tracked = []
            self.model.selected = nil
            if let o = self.observer { NotificationCenter.default.removeObserver(o); self.observer = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The policy switch and the system's activation can race; order front once more on the next turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Takes a download out of the window; closes the window when it was the last one.
    func close(id: UUID) {
        guard let i = model.tracked.firstIndex(of: id) else { return }
        guard model.tracked.count > 1 else { window?.close(); return }
        model.tracked.remove(at: i)
        if model.selected == id { model.selected = model.tracked[min(i, model.tracked.count - 1)] }
        if let store = AppDelegate.sharedStore { layout(store: store, animate: true) }
    }

    /// Closes the window when it shows only this download; with other downloads in the list it stays open.
    /// Closing the window never stops a download: the main window still lists and controls it.
    func closeIfAlone(id: UUID) {
        if model.tracked == [id] { window?.close() }
    }

    func resize(id: UUID, compact: Bool) {
        self.compact = compact
        if let store = AppDelegate.sharedStore { layout(store: store, animate: true) }
    }

    /// İndirme bitince: otomatik kapat ya da "tamamlandı" boyutuna küçült.
    func didComplete(id: UUID, autoClose: Bool) {
        guard model.tracked.contains(id) else { return }
        if autoClose {
            close(id: id)
        } else if let store = AppDelegate.sharedStore {
            layout(store: store, animate: true)
        }
    }

    /// Size for what is shown: the list keeps a full-height window; a single download sizes to its view.
    private func layout(store: DownloadStore, animate: Bool) {
        guard let w = window else { return }
        let width = Self.detailWidth + (showsList ? Self.listWidth : 0)
        var height = Self.fullHeight
        if !showsList, let id = model.tracked.first, let item = store.items.first(where: { $0.id == id }) {
            height = item.state == .completed ? Self.completedHeight : (compact ? Self.compactHeight : Self.fullHeight)
        }
        w.contentMinSize = NSSize(width: width, height: min(height, Self.completedHeight))
        var frame = w.frame
        let content = w.contentRect(forFrameRect: frame)
        let dh = height - content.height
        frame.size.height += dh
        frame.origin.y -= dh
        frame.size.width += width - content.width
        w.setFrame(frame, display: true, animate: animate)
    }

    /// Başlığı ilerlemeye göre günceller ("%24 · dosya.zip" ya da "%40 · 3 indirme").
    func refreshTitles(items: [DownloadItem]) {
        guard let w = window else { return }
        // Downloads removed from the main list leave the window too.
        let live = model.tracked.filter { id in items.contains { $0.id == id } }
        if live.isEmpty { if !model.tracked.isEmpty { w.close() }; return }
        if live != model.tracked {
            model.tracked = live
            if let s = model.selected, !live.contains(s) { model.selected = live.first }
            if let store = AppDelegate.sharedStore { layout(store: store, animate: true) }
        }
        let shown = live.compactMap { id in items.first { $0.id == id } }
        let title: String
        if shown.count == 1, let item = shown.first {
            let pct = item.totalBytes > 0 && item.state != .completed ? "\(Int(item.progress * 100))% · " : ""
            title = pct + item.fileName
        } else {
            let measurable = shown.filter { $0.state.isActive && $0.totalBytes > 0 }
            let total = measurable.reduce(Int64(0)) { $0 + $1.totalBytes }
            let got = measurable.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
            let pct = total > 0 ? "\(Int(Double(got) * 100 / Double(total)))% · " : ""
            title = pct + String(localized: "\(shown.count) downloads")
        }
        if w.title != title { w.title = title }
    }
}
