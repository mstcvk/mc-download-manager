import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let showAddSheet = Notification.Name("dm.showAddSheet")
}

enum SidebarItem: Hashable {
    case all
    case category(FileCategory)
    case finished
    case unfinished
}

struct ContentView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @State private var showAdd = false
    @State private var sidebar: SidebarItem? = .all
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\DownloadItem.createdAt, order: .reverse)]
    @State private var showCategories = true
    @State private var showOnboarding = false

    private var filtered: [DownloadItem] {
        var list = store.items
        switch sidebar ?? .all {
        case .all: break
        case .category(let c): list = list.filter { $0.category == c }
        case .finished: list = list.filter { $0.isFinished }
        case .unfinished: list = list.filter { !$0.isFinished }
        }
        if !search.isEmpty {
            list = list.filter {
                $0.fileName.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search)
            }
        }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            VStack(spacing: 0) {
                if filtered.isEmpty { emptyState } else { table }
                Divider()
                statusBar
            }
        }
        .navigationTitle("MC Download Manager")
        .frame(minWidth: 860, minHeight: 480)
        .searchable(text: $search, placement: .toolbar, prompt: "Search in the list")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAdd) { AddDownloadView() }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear { if !settings.onboardingDone { showOnboarding = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showAddSheet)) { _ in showAdd = true }
        .onDrop(of: [.url, .plainText], isTargeted: nil, perform: handleDrop)
        .focusable()
        .onDeleteCommand { selection.forEach { store.remove($0) }; selection.removeAll() }
        .onPasteCommand(of: [.url, .plainText, .utf8PlainText]) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: String.self) {
                    _ = p.loadObject(ofClass: String.self) { text, _ in
                        guard let text else { return }
                        DispatchQueue.main.async { ClipboardWatcher.shared.handlePaste(text: text) }
                    }
                } else if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { ClipboardWatcher.shared.handlePaste(text: url.absoluteString) }
                    }
                }
            }
        }
    }

    // MARK: Sidebar

    private var sidebarView: some View {
        List(selection: $sidebar) {
            DisclosureGroup(isExpanded: $showCategories) {
                ForEach(FileCategory.allCases) { c in
                    Label(c.label, systemImage: c.symbol)
                        .badge(count(for: .category(c)))
                        .tag(SidebarItem.category(c))
                }
            } label: {
                Label("All", systemImage: "folder").font(.headline).tag(SidebarItem.all)
            }
            Label("Finished", systemImage: "checkmark.circle").font(.headline)
                .badge(count(for: .finished)).tag(SidebarItem.finished)
            Label("Unfinished", systemImage: "clock.arrow.circlepath").font(.headline)
                .badge(count(for: .unfinished)).tag(SidebarItem.unfinished)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    private func count(for item: SidebarItem) -> Int {
        switch item {
        case .all: return store.items.count
        case .category(let c): return store.items.filter { $0.category == c }.count
        case .finished: return store.items.filter { $0.isFinished }.count
        case .unfinished: return store.items.filter { !$0.isFinished }.count
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAdd = true } label: { Label("Add URL", systemImage: "link.badge.plus") }
                .help("Add a download by URL (⌘N)")
            Button { store.resumeAll() } label: { Label("Start Queue", systemImage: "play") }
                .help("Resume paused and failed downloads")
            Button { store.pauseAll() } label: { Label("Stop All", systemImage: "stop") }
                .help("Pause all downloads")
            Button { store.clearFinished() } label: { Label("Clear Finished", systemImage: "trash") }
                .help("Remove completed and cancelled items from the list")
            if #available(macOS 14.0, *) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            } else {
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Table

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.fileName) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.category.symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName).lineLimit(1).truncationMode(.middle)
                        Text(item.category.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 200, ideal: 290)

            TableColumn("Size", value: \.totalBytes) { item in
                Text(item.totalBytes > 0 ? Fmt.size(item.totalBytes) : (item.receivedBytes > 0 ? Fmt.size(item.receivedBytes) : "—"))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 95)

            TableColumn("Status", value: \.state.rawValue) { item in
                StatusCell(item: item)
            }
            .width(min: 140, ideal: 170)

            TableColumn("Speed", value: \.speed) { item in
                Text(item.state == .downloading && item.speed > 0 ? Fmt.speed(item.speed) : "")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 95)

            TableColumn("Time Left") { item in
                Text(item.state == .downloading ? (item.eta.map { Fmt.duration($0) } ?? "") : "")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 95)

            TableColumn("Date Added", value: \.createdAt) { item in
                Text(item.createdAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            for id in ids { DetailWindowManager.shared.show(id: id, store: store) }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let items = store.items.filter { ids.contains($0.id) }
        if items.isEmpty {
            Button("Add URL…") { showAdd = true }
        } else {
            Button("Open Download Window") { ids.forEach { DetailWindowManager.shared.show(id: $0, store: store) } }
            Divider()
            if items.contains(where: { $0.state == .queued }) {
                Button("Start Download") { ids.forEach { store.start($0) } }
            }
            if items.contains(where: { $0.state.isActive || $0.state == .queued }) {
                Button("Pause") { ids.forEach { store.pause($0) } }
                Button("Cancel") { ids.forEach { store.cancel($0) } }
            }
            if items.contains(where: { [.paused, .failed, .cancelled].contains($0.state) }) {
                Button("Resume / Retry") { ids.forEach { store.resume($0) } }
            }
            if items.contains(where: { $0.kind == .file && $0.state == .failed }) {
                Button("Download in Browser") {
                    items.filter { $0.kind == .file && $0.state == .failed }.forEach { store.handOffToBrowser($0.id) }
                    selection.subtract(ids)
                }
            }
            if items.count == 1, let item = items.first {
                Divider()
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                }
                if item.state == .completed {
                    Button("Open") { store.open(item) }
                    Button("Show in Finder") { store.revealInFinder(item) }
                }
            }
            Divider()
            Button("Remove from List") { ids.forEach { store.remove($0) }; selection.subtract(ids) }
            if items.contains(where: { $0.state == .completed }) {
                Button("Move File to Trash and Remove", role: .destructive) {
                    ids.forEach { store.remove($0, deleteFile: true) }
                    selection.subtract(ids)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            if search.isEmpty {
                Text("No downloads in this view").font(.title2)
                Text("Download a file from your browser, drop a link here,\nor press ⌘N to enter a URL.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("No matching downloads").font(.title2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Circle().fill(server.running ? Color.green : Color.red).frame(width: 8, height: 8)
            if server.running {
                Text("Browser bridge is running").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(server.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(store.items.filter { !$0.isFinished }.count)", systemImage: "list.bullet")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Unfinished downloads")
            Label(Fmt.speed(store.totalSpeed), systemImage: "icloud.and.arrow.down")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Total download speed")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { store.addURLs(url.absoluteString, kind: .file) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async { store.addURLs(text, kind: .file) }
                }
            }
        }
        return true
    }
}

/// Status column: percentage + state text + thin progress bar.
struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).lineLimit(1).foregroundStyle(item.state == .failed ? .red : .primary)
            if showsBar {
                SegmentBar(segments: item.segments, total: item.totalBytes, fallback: item.progress, tint: tint)
                    .frame(height: 5)
                    .frame(maxWidth: 160)
            }
        }
        .padding(.vertical, 2)
    }

    private var showsBar: Bool {
        [.downloading, .paused, .probing].contains(item.state) || (item.state == .queued && item.receivedBytes > 0)
    }

    private var text: String {
        switch item.state {
        case .completed: return String(localized: "Completed")
        case .queued: return String(localized: "Added")
        case .failed: return String(localized: "Error: \(item.errorMessage ?? "")")
        case .downloading, .paused, .probing:
            let pct = item.totalBytes > 0 ? "\(Int(item.progress * 100))% " : ""
            if item.kind != .file, item.state == .downloading, !item.stage.isEmpty { return pct + item.stage }
            return pct + item.state.label
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    private var tint: Color {
        switch item.state {
        case .paused: return .orange
        case .failed: return .red
        default: return .accentColor
        }
    }
}

/// Bar showing how much of each segment has been received.
struct SegmentBar: View {
    let segments: [SegmentInfo]
    let total: Int64
    let fallback: Double
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            ctx.fill(bg, with: .color(.gray.opacity(0.25)))
            ctx.clip(to: bg)
            if segments.isEmpty || total <= 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * fallback, height: size.height)), with: .color(tint))
            } else {
                for s in segments where s.received > 0 {
                    let x = CGFloat(s.start) / CGFloat(total) * size.width
                    let w = CGFloat(s.received) / CGFloat(total) * size.width
                    ctx.fill(Path(CGRect(x: x, y: 0, width: max(w, 1), height: size.height)), with: .color(tint))
                }
                for s in segments.dropFirst() {
                    let x = CGFloat(s.start) / CGFloat(total) * size.width
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.6)))
                }
            }
        }
        .frame(height: 7)
    }
}
