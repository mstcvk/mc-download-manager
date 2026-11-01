import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AddDownloadView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var asVideo = false
    @State private var segments = 0
    @State private var importError: String?

    private var invalidLinks: Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)) else { return true }
            return !TorrentDownloader.accepts(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Download").font(.title2.bold())
            Text("One HTTP(S) URL or magnet link per line; use the button for .torrent files.").foregroundStyle(.secondary).font(.callout)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if invalidLinks {
                Text("Enter valid HTTP(S) URLs or BitTorrent v1 magnet links.")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("Magnet links use aria2c (brew install aria2). Choose torrent files before downloading; uploading stops when complete.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Torrent File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        _ = try store.importTorrent(url)
                        dismiss()
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
            Toggle("Download video from page (yt-dlp)", isOn: $asVideo)
            if !asVideo {
                Stepper(value: $segments, in: 0...16) {
                    if segments == 0 {
                        Text("Connections: default (\(settings.segmentCount))")
                    } else {
                        Text("Connections: \(segments)")
                    }
                }
            }
            HStack {
                Button("Paste from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    store.addURLs(text, kind: asVideo ? .video : .file, segments: segments == 0 ? nil : segments)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invalidLinks || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Couldn’t import torrent file", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               (s.hasPrefix("http") || s.lowercased().hasPrefix("magnet:")), !s.contains("\n") {
                text = s
            }
        }
    }
}
