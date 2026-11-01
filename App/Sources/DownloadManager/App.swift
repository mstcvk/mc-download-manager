import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

/// Shared model objects, created once before the first App body evaluation.
final class AppCore {
    static let shared = AppCore()
    let settings: AppSettings
    let store: DownloadStore
    let server: ServerController

    private init() {
        settings = AppSettings.shared
        store = DownloadStore(settings: settings)
        server = ServerController(store: store, settings: settings)
        AppDelegate.sharedStore = store
        ClipboardWatcher.shared.start(store: store, settings: settings)
        UpdateChecker.shared.start(store: store, settings: settings)
    }
}

// The entry point lives in main.swift: it picks `DownloadManagerApp15` on macOS 15+ (where the main window
// can be kept closed at launch with `defaultLaunchBehavior`) and `DownloadManagerApp` on macOS 13/14, where
// AppPresence.finishLaunch closes the window right after launch instead.

struct DownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let core = AppCore.shared

    var body: some Scene {
        Window("MC Download Manager", id: "main") { MainWindowContent(core: core) }
            .mainCommands()
        SharedScenes(core: core)
    }
}

@available(macOS 15.0, *)
struct DownloadManagerApp15: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let core = AppCore.shared

    var body: some Scene {
        Window("MC Download Manager", id: "main") { MainWindowContent(core: core) }
            .defaultLaunchBehavior(AppPresence.shared.startsHidden ? .suppressed : .presented)
            .restorationBehavior(.disabled)
            .mainCommands()
        SharedScenes(core: core)
    }
}

struct MainWindowContent: View {
    let core: AppCore
    var body: some View {
        ContentView()
            .environmentObject(core.store)
            .environmentObject(core.settings)
            .environmentObject(core.server)
    }
}

extension Scene {
    func mainCommands() -> some Scene {
        commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") { NotificationCenter.default.post(name: .showAddSheet, object: nil) }
                    .keyboardShortcut("n")
                Button("Open Torrent File…") { AppDelegate.openTorrentFile() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.check(interactive: true) }
            }
        }
    }
}

/// Settings window and the menu bar item, shared by both App variants.
struct SharedScenes: Scene {
    let core: AppCore

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(core.settings)
                .environmentObject(core.server)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(core.store)
                .environmentObject(core.server)
        } label: {
            MenuBarLabel(store: core.store)
        }
    }
}

/// Status bar icon. It is always alive, so it also serves as the hook that opens the main window
/// from AppKit code (AppDelegate reopen, menu bar "Show Window") through the SwiftUI `openWindow` action.
struct MenuBarLabel: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(store.activeCount > 0 ? "MenuBarIconActive" : "MenuBarIcon")
                .renderingMode(.template)
            if store.activeCount > 0, let p = store.overallProgress {
                Text("\(Int(p * 100))%").font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var server: ServerController

    var body: some View {
        if store.activeCount > 0 {
            Text("\(store.activeCount) downloading · \(Fmt.speed(store.totalSpeed))")
        } else {
            Text("No active downloads")
        }
        if server.running { Text("Bridge is running") } else { Text("Bridge is not running") }
        Divider()
        Button("Show Window") {
            AppPresence.shared.showMainWindow()
        }
        Button("New Download…") {
            AppPresence.shared.showMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .showAddSheet, object: nil)
            }
        }
        Divider()
        Button("Pause All") { store.pauseAll() }
        Button("Resume All") { store.resumeAll() }
        Divider()
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
        }
        Button("Check for Updates…") { UpdateChecker.shared.check(interactive: true) }
        Divider()
        Button("Quit MC Download Manager") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var sharedStore: DownloadStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPresence.shared.prepareLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.shared.finishLaunch()
        LoginItem.registerByDefaultIfNeeded()
        DispatchQueue.global(qos: .utility).async { NativeHostRegistry.register() }
        if AppSettings.shared.onboardingDone {
            Self.sharedStore?.prepareDownloadFolder()
            // Plugin folders live under the download folder: only touch them once its access was granted.
            DispatchQueue.global(qos: .utility).async { BrowserIntegration.refreshOutdatedPluginFolders() }
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let store = Self.sharedStore ?? AppCore.shared.store
        for url in urls {
            if TorrentDownloader.isMagnet(url) {
                if let existing = store.items.first(where: { $0.url == url && $0.state != .cancelled && $0.state != .failed }) {
                    DetailWindowManager.shared.show(id: existing.id, store: store)
                } else {
                    var request = NewDownloadRequest(url: url)
                    request.kind = .torrent
                    let item = store.add(request)
                    DetailWindowManager.shared.show(id: item.id, store: store)
                }
            } else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
                Self.importTorrent(url)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { importTorrent(url) }
    }

    private static func importTorrent(_ url: URL) {
        do {
            _ = try (sharedStore ?? AppCore.shared.store).importTorrent(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Couldn’t import torrent file", comment: "")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppPresence.shared.showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.sharedStore?.shutdown()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
