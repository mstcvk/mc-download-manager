import Foundation

final class DetailWindowManager {
    static let shared = DetailWindowManager()
    func show(id: UUID, store: DownloadStore) {}
    func didComplete(id: UUID, autoClose: Bool) {}
    func refreshTitles(items: [DownloadItem]) {}
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let original = try Data(contentsOf: source)
let settings = AppSettings.shared
settings.downloadDirectory = root.appendingPathComponent("payload").path
settings.autoStart = false
settings.showDetailOnStart = false
settings.notifyOnComplete = false
settings.maxConcurrent = 1
let support = root.appendingPathComponent("support")
let store = DownloadStore(settings: settings, supportDirectory: support)
let item = try store.importTorrent(source)
let destination = TorrentDownloader.directory(for: item)
assert(item.torrentFiles?.map(\.length) == [4194304, 4194304])
assert((try? Data(contentsOf: source)) == original)
store.selectTorrentFiles(item.id, indices: [2])
let deadline = Date().addingTimeInterval(90)
while Date() < deadline {
    guard let current = store.items.first(where: { $0.id == item.id }) else { fatalError("Missing item") }
    if current.receivedBytes > 0 { break }
    if current.state == .failed || current.state == .completed { fatalError("Unexpected state: \(current.state), \(current.errorMessage ?? current.log)") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
let progress = store.items.first(where: { $0.id == item.id })!.receivedBytes
assert(progress > 0, "Timed out waiting for payload")
store.shutdown()
let controls = FileManager.default.enumerator(atPath: destination.path)!.allObjects.compactMap { $0 as? String }
assert(controls.contains { $0.hasSuffix(".aria2") }, "Missing resume control file")
assert((try? Data(contentsOf: source)) == original)
try FileManager.default.removeItem(at: source)
let restored = DownloadStore(settings: settings, supportDirectory: support)
let saved = restored.items.first(where: { $0.id == item.id })!
assert(saved.state == .paused && saved.selectedTorrentFiles == [2])
restored.resume(item.id)
let finishDeadline = Date().addingTimeInterval(90)
while Date() < finishDeadline {
    let current = restored.items.first(where: { $0.id == item.id })!
    if current.state == .completed { break }
    if current.state == .failed { fatalError("Resume failed: \(current.errorMessage ?? current.log)") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
let finished = restored.items.first(where: { $0.id == item.id })!
assert(finished.state == .completed, "Timed out resuming: \(finished.log)")
assert(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("sample/first.bin").path))
assert(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sample/second.bin").path))
restored.shutdown()
print("PASS: imported torrent resumed selected file after restart and original removal: \(destination.path)")
