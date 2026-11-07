import SwiftUI
import AppKit

struct AddDownloadView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var asVideo = false
    @State private var segments = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Download").font(.title2.bold())
            Text("One URL per line.").foregroundStyle(.secondary).font(.callout)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
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
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http"), !s.contains("\n") {
                text = s
            }
        }
    }
}
