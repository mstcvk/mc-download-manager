import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .aqua)
let files = [
    TorrentFile(id: 1, path: "Örnek Torrent/Film.mkv", length: 1_500_000_000),
    TorrentFile(id: 2, path: "Örnek Torrent/Altyazılar/Türkçe.srt", length: 85_000),
    TorrentFile(id: 3, path: "Örnek Torrent/Belgeler/Uzun dosya adlarının satıra sığması için örnek açıklama.txt", length: 2400)
]
let item = DownloadItem(url: URL(string: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))!,
                        fileName: "Örnek Torrent", directory: FileManager.default.temporaryDirectory, kind: .torrent)
let view = TorrentFileSelectionView(item: item, files: files, onSelect: { _ in }, onLater: {})
    .padding(20).frame(width: 560, height: 470)
    .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor))
let hosting = NSHostingView(rootView: view)
let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 470),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = hosting
window.orderFront(nil)
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
hosting.layoutSubtreeIfNeeded()
let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
window.orderOut(nil)
print("File selection view rendered")
