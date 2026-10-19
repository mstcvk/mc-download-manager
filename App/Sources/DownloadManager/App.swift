import SwiftUI
import AppKit
import UserNotifications

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
    @ObservedObject private var settings = AppSettings.shared

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
        Toggle("Limit Torrent Speed (\(Fmt.speed(Double(settings.torrentLimitKB) * 1024)))", isOn: $settings.torrentLimitEnabled)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// magnet: links and .torrent files opened from the browser or Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let store = Self.sharedStore else { return }
        for url in urls where TorrentInput.isTorrent(url) {
            store.addURLs(url.isFileURL ? url.path : url.absoluteString, kind: .torrent)
        }
    }

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
