import Foundation

let args = CommandLine.arguments
let magnet = URL(string: args[1])!
let directory = URL(fileURLWithPath: args[2])
let executable = TorrentDownloader.locate()!
var status: Int32?
var received: Int64 = 0
var firstResumedBytes: Int64?
var pausing = false
var process: Process!
func launch(resuming: Bool) throws {
    status = nil
    process = try TorrentDownloader.launch(executable: executable, url: try TorrentDownloader.metadataFile(in: directory.appendingPathComponent(".metadata")), directory: directory,
        onLine: { line in
            print(line)
            if let progress = TorrentDownloader.progress(in: line) {
                received = progress.received
                if resuming {
                    if firstResumedBytes == nil { firstResumedBytes = received }
                } else if received >= 262144 && !pausing {
                    pausing = true
                    process.terminate()
                }
            }
        }, onFinish: { status = $0 })
}
func awaitExit() {
    let deadline = Date().addingTimeInterval(90)
    while status == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    if status == nil {
        process.terminate()
        fatalError("aria2 did not finish within 90 seconds")
    }
}
// Fetch only metadata first, exactly as the app does before presenting file selection.
let metadataDirectory = directory.appendingPathComponent(".metadata")
process = try TorrentDownloader.launch(executable: executable, url: magnet, directory: metadataDirectory,
    metadataOnly: true, onLine: { print($0) }, onFinish: { status = $0 })
awaitExit()
assert(status == 0)
assert(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("sample").path))
let metadata = try TorrentDownloader.metadataFile(in: metadataDirectory)
let files = try TorrentDownloader.files(in: Data(contentsOf: metadata))
assert(files.count == 2 && files.map(\.id) == [1, 2])
assert(files.map(\.length) == [4194304, 4194304])
print("TEST: metadata-only fetch lists both files without downloading payload")
try launch(resuming: false)
awaitExit()
assert(pausing, "Did not reach real payload progress before exit")
let pausedBytes = received
assert(pausedBytes > 0)
let controls = FileManager.default.enumerator(atPath: directory.path)!.allObjects.compactMap { $0 as? String }
assert(controls.contains { $0.hasSuffix(".aria2") }, "Missing resume control file")
print("TEST: paused after \(pausedBytes) bytes; resuming")
try launch(resuming: true)
awaitExit()
assert(status == 0, "Resumed torrent failed")
assert((firstResumedBytes ?? 0) >= pausedBytes, "Resume discarded completed pieces")
assert(received > pausedBytes)
print("TEST: magnet metadata, progress, pause/resume, completion and automatic exit passed")

// Download only the second file into a separate destination, using the cached metadata.
let selectedDirectory = directory.appendingPathComponent("selected-only")
status = nil
process = try TorrentDownloader.launch(executable: executable, url: metadata, directory: selectedDirectory,
    selectedFiles: [2], onLine: { print($0) }, onFinish: { status = $0 })
awaitExit()
assert(status == 0)
assert(!FileManager.default.fileExists(atPath: selectedDirectory.appendingPathComponent("sample/first.bin").path))
assert(FileManager.default.fileExists(atPath: selectedDirectory.appendingPathComponent("sample/second.bin").path))
print("TEST: only selected file downloaded; unselected piece-aligned file was not created")
