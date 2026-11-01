import Foundation

let hex = String(repeating: "a", count: 40)
let magnet = URL(string: "magnet:?xt=urn:btih:\(hex)&dn=Example%20files")!
assert(TorrentDownloader.isMagnet(magnet))
assert(TorrentDownloader.isMagnet(URL(string: "MAGNET:?xt=urn:btih:" + String(repeating: "A", count: 32))!))
let mixedCase = URL(string: "MAGNET:?XT=URN:BTIH:" + String(repeating: "a", count: 32) + "&dn=Mixed")!
assert(TorrentDownloader.normalizedMagnet(mixedCase)?.absoluteString == "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32) + "&dn=Mixed")
assert(!TorrentDownloader.isMagnet(URL(string: "magnet://host/path?xt=urn:btih:" + hex)!))
for text in ["magnet:?dn=OnlyName", "magnet:?xt=urn:btih:" + String(repeating: "ß", count: 32), "magnet:?xt=urn:btih:123", "magnet:?xt=urn:btih:" + String(repeating: "z", count: 40), "https://example.org/"] {
    assert(!TorrentDownloader.isMagnet(URL(string: text)!))
}
assert(!TorrentDownloader.accepts(URL(string: "file:///etc/passwd")!))
assert(!TorrentDownloader.accepts(URL(string: "https:missing-host")!))
assert(TorrentDownloader.accepts(URL(string: "https://example.org/file.zip")!))
assert(TorrentDownloader.name(for: magnet) == "Example files")
let progress = TorrentDownloader.progress(in: "[#abcdef 1024B/4096B(25%) CN:3 SD:1 DL:512B UL:0B(0B)]")!
assert(progress.received == 1024 && progress.total == 4096 && progress.speed == 512)
assert(TorrentDownloader.progress(in: "[#abcdef 1/4(25%) CN:1 DL:2]")?.received == 1)
assert(TorrentDownloader.progress(in: "[#abcdef 1/4(25%) CN:1 DL:2] [METADATA]") == nil)
assert(TorrentDownloader.progress(in: "[#abcdef 0B/0B(0%) CN:0 DL:0B]") == nil)
assert(TorrentDownloader.progress(in: "unrelated output") == nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let args = TorrentDownloader.arguments(url: magnet, directory: directory)
assert(args.contains("--no-conf=true") && args.contains("--seed-time=0"))
assert(args.contains("--no-netrc=true"))
assert(args.contains("--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)"))
assert(args.contains("--allow-overwrite=false") && args.contains("--check-integrity=true"))
assert(args.suffix(2) == ["--", magnet.absoluteString])
assert(TorrentDownloader.arguments(url: mixedCase, directory: directory).last == TorrentDownloader.normalizedMagnet(mixedCase)?.absoluteString)
var item = DownloadItem(url: magnet, fileName: "Example", directory: directory, kind: .torrent)
let originalDirectory = TorrentDownloader.directory(for: item)
item.fileName = "Renamed"
assert(TorrentDownloader.directory(for: item) == originalDirectory)
let saved = try JSONEncoder().encode(item)
let restored = try JSONDecoder().decode(DownloadItem.self, from: saved)
assert(restored.kind == .torrent)
// Exercise the real pipe reader with CR output, UTF-8, final unterminated line and nonzero exit.
let fake = directory.appendingPathComponent("fake-aria2c")
try "#!/bin/sh\nprintf 'first\\rTürkçe\\nlast'\nexit 7\n".write(to: fake, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
var lines: [String] = []
var status: Int32?
let process = try TorrentDownloader.launch(executable: fake.path, url: magnet, directory: directory,
    onLine: { lines.append($0) }, onFinish: { status = $0 })
let deadline = Date().addingTimeInterval(5)
while status == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
assert(status == 7 && lines == ["first", "Türkçe", "last"])
assert(!process.isRunning)
print("Torrent checks passed")

func bstring(_ text: String) -> String { "\(text.utf8.count):" + text }
let single = Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678906:lengthi123e4:name8:test.binee".utf8)
let singleFiles = try TorrentDownloader.files(in: single)
assert(singleFiles == [TorrentFile(id: 1, path: "test.bin", length: 123)])
let multi = Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678905:filesld6:lengthi10e4:pathl5:a.txteed6:lengthi20e4:pathl5:b.txteee4:name4:rootee".utf8)
let multiFiles = try TorrentDownloader.files(in: multi)
assert(multiFiles == [TorrentFile(id: 1, path: "root/a.txt", length: 10), TorrentFile(id: 2, path: "root/b.txt", length: 20)])
let invalidMetadata = [
    Data(), Data("d4:info".utf8), Data((String(repeating: "l", count: 40) + "e").utf8),
    Data("9999999999999999999999999999:x".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678906:lengthi-1e4:name8:test.binee".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678906:lengthi1e4:name2:..ee".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678906:lengthi1e4:name9:.metadataee".utf8),
    Data("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678905:filesld6:lengthi1e4:pathl2:..eee4:name4:rootee".utf8),
    single + Data("TRAILING".utf8),
    Data("d4:infod6:lengthi1e4:name1:a12:piece lengthi1024eee".utf8),
    Data("d4:infod6:lengthi1e4:name1:a12:piece lengthi1024e6:pieces19:1234567890123456789ee".utf8),
    Data("d4:infod4:attr1:l6:lengthi1e4:name1:a12:piece lengthi1024e6:pieces20:12345678901234567890ee".utf8),
    Data("d4:infod5:filesld4:attr1:l6:lengthi1e4:pathl1:aeee4:name4:root12:piece lengthi1024e6:pieces20:12345678901234567890ee".utf8),
    Data("d4:infod5:filesld6:lengthi1e4:pathl1:aeee6:lengthi1e4:name4:root12:piece lengthi1024e6:pieces20:12345678901234567890ee".utf8),
    Data("d4:infod9:file treede12:meta versioni2e4:name1:a12:piece lengthi16384eee".utf8)
]
func metadata(paths: [[String]]) -> Data {
    let entries = paths.map { "d6:lengthi1e4:pathl" + $0.map(bstring).joined() + "ee" }.joined()
    return Data(("d4:infod12:piece lengthi1024e6:pieces20:123456789012345678905:filesl" + entries + "e4:name4:rootee").utf8)
}
let conflictingPaths = [
    [["A.txt"], ["a.txt"]],
    [["é.txt"], ["e\u{301}.txt"]],
    [["folder"], ["folder", "file.txt"]],
    [["FOLDER", "file.txt"], ["folder"]],
    [["a"], ["a-b"], ["a", "nested"]]
]
assert((try? TorrentDownloader.files(in: metadata(paths: [["a.txt"], ["b.txt"]])))?.count == 2)
for data in invalidMetadata + conflictingPaths.map({ metadata(paths: $0) }) {
    do { _ = try TorrentDownloader.files(in: data); assertionFailure("Accepted invalid metadata") }
    catch { }
}
assert(TorrentDownloader.arguments(url: magnet, directory: directory, metadataOnly: true).contains("--bt-metadata-only=true"))
assert(TorrentDownloader.arguments(url: magnet, directory: directory, selectedFiles: [2, 1]).contains("--select-file=1,2"))
item.torrentFiles = multiFiles
item.selectedTorrentFiles = [2]
let selectionData = try JSONEncoder().encode(item)
let restoredSelection = try JSONDecoder().decode(DownloadItem.self, from: selectionData)
assert(restoredSelection.torrentFiles == multiFiles && restoredSelection.selectedTorrentFiles == [2])
var legacy = try JSONSerialization.jsonObject(with: selectionData) as! [String: Any]
legacy.removeValue(forKey: "torrentFiles")
legacy.removeValue(forKey: "selectedTorrentFiles")
let oldData = try JSONSerialization.data(withJSONObject: legacy)
let oldItem = try JSONDecoder().decode(DownloadItem.self, from: oldData)
assert(oldItem.torrentFiles == nil && oldItem.selectedTorrentFiles == nil)
print("Metadata parsing, selection arguments and old saved downloads passed")
