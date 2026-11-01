import Foundation

// Keep queue tests headless; exercise the real store, settings, and download engines.
final class DetailWindowManager {
    static let shared = DetailWindowManager()
    var shown: [UUID] = []
    func show(id: UUID, store: DownloadStore) { shown.append(id) }
    func didComplete(id: UUID, autoClose: Bool) {}
    func refreshTitles(items: [DownloadItem]) {}
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: directory)
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
}
let settings = AppSettings.shared
settings.downloadDirectory = directory.path
settings.autoStart = false
settings.showDetailOnStart = false
settings.notifyOnComplete = false
settings.maxConcurrent = 1
let magnet = URL(string: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))!
var chooser = DownloadItem(url: magnet, fileName: "Waiting for selection", directory: directory, kind: .torrent)
chooser.state = .paused
chooser.torrentFiles = [TorrentFile(id: 1, path: "test.bin", length: 123)]
let storeURL = directory.appendingPathComponent("downloads.json")
try JSONEncoder().encode([chooser]).write(to: storeURL)
let store = DownloadStore(settings: settings, supportDirectory: directory)
let next = store.add(NewDownloadRequest(url: URL(string: "http://127.0.0.1:1/test")!))
store.resume(chooser.id)
assert(store.items.first { $0.id == chooser.id }?.state == .paused)
assert(DetailWindowManager.shared.shown == [chooser.id])
assert(store.items.first { $0.id == next.id }?.state == .probing, "A selection prompt must not consume a download slot")
store.shutdown()

// Peer-supplied lengths can be valid individually and overflow their combined Int64 sum.
settings.maxConcurrent = 2
var large = DownloadItem(url: URL(string: "http://127.0.0.1:1/large")!, fileName: "large", directory: directory)
large.totalBytes = Int64.max
var other = large
other.id = UUID()
try JSONEncoder().encode([large, other]).write(to: storeURL)
let largeStore = DownloadStore(settings: settings, supportDirectory: directory)
largeStore.resumeAll()
assert(largeStore.activeCount == 2)
assert(largeStore.overallProgress == 0)
largeStore.shutdown()
print("Store queue selection and combined-size overflow checks passed")

// Imported metadata is copied before insertion and never depends on the original again.
let source = directory.appendingPathComponent("source.torrent")
let bytes = Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678905:filesld6:lengthi10e4:pathl5:a.txteed6:lengthi20e4:pathl5:b.txteee4:name4:rootee".utf8)
try bytes.write(to: source)
let importStore = DownloadStore(settings: settings, supportDirectory: directory)
let imported = try importStore.importTorrent(source)
let snapshot = try TorrentDownloader.metadataFile(in: TorrentDownloader.metadataDirectory(for: imported))
assert((try? Data(contentsOf: source)) == bytes)
assert((try? Data(contentsOf: snapshot)) == bytes)
assert(imported.state == .paused && imported.torrentFiles?.map(\.path) == ["root/a.txt", "root/b.txt"])
assert(DetailWindowManager.shared.shown.last == imported.id)
// Occupy the queue while choosing, then persist as a paused download.
settings.maxConcurrent = 1
importStore.resumeAll()
importStore.selectTorrentFiles(imported.id, indices: [2])
importStore.shutdown()
try FileManager.default.removeItem(at: source)
let restoredStore = DownloadStore(settings: settings, supportDirectory: directory)
let restoredImport = restoredStore.items.first { $0.id == imported.id }!
assert(restoredImport.selectedTorrentFiles == [2] && restoredImport.torrentFiles == imported.torrentFiles)
assert((try? TorrentDownloader.metadataData(at: snapshot)) == bytes)
try FileManager.default.removeItem(at: snapshot)
restoredStore.resume(imported.id)
assert(restoredStore.items.first { $0.id == imported.id }?.state == .failed)
restoredStore.shutdown()

for (index, invalid) in [Data("bad".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678906:lengthi1e4:name2:..ee".utf8),
    Data("d4:infod12:piece lengthi0e6:pieces20:123456789012345678906:lengthi1e4:name1:aee".utf8),
    Data("d4:infod12:piece lengthi2147483648e6:pieces20:123456789012345678906:lengthi1e4:name1:aee".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces0:6:lengthi1e4:name1:aee".utf8),
    Data(repeating: 0, count: 16 * 1024 * 1024 + 1)].enumerated() {
    let bad = directory.appendingPathComponent("bad-\(index).torrent")
    try invalid.write(to: bad)
    let count = restoredStore.items.count
    do { _ = try restoredStore.importTorrent(bad); assertionFailure("Accepted invalid torrent") } catch { }
    assert(restoredStore.items.count == count)
    assert((try? Data(contentsOf: bad)) == invalid)
}
print("Local torrent import, snapshot persistence and invalid metadata checks passed")

let realSource = directory.appendingPathComponent("real.torrent")
let link = directory.appendingPathComponent("link.torrent")
try bytes.write(to: realSource)
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realSource)
do { _ = try restoredStore.importTorrent(link); assertionFailure("Accepted symlink") } catch { }
