// The caption window: each line as heard (gray while the sentence goes on) with its Chinese under
// it, newest at the bottom; a bar with Start/Stop, the status and Settings.

import AppKit
import OwnVoiceCore
import SwiftUI

struct CaptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let style = CaptionStyle.of(model.settings)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.book.lines.isEmpty {
                            Text("Captions appear here: what is said, and its Chinese under it.")
                                .font(style.font(size: 14))
                                .foregroundStyle(style.partial)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.book.lines) { line in
                            CaptionRow(line: line, fontSize: model.settings.fontSize, style: style)
                                .id(line.id)
                        }
                    }
                    .padding(16)
                }
                .background(style.background ?? .clear)
                .onChange(of: model.book.lines.last) { _, last in
                    if let last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button(model.isListening ? LocalizedStringKey("Stop") : LocalizedStringKey("Start"), systemImage: model.isListening ? "stop.fill" : "mic.fill") {
                    model.toggle()
                }
                .keyboardShortcut("l")
                .tint(model.isListening ? .red : .accentColor)
                Text(verbatim: model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button("Reply", systemImage: "text.bubble") { openWindow(id: "reply") }
                    .labelStyle(.iconOnly)
                    .help("Reply: type Chinese, read the words aloud")
                Button("Script", systemImage: "doc.text") { openWindow(id: "script") }
                    .labelStyle(.iconOnly)
                    .help("Script")
                Button("Summary", systemImage: "list.bullet.rectangle") { openWindow(id: "summary") }
                    .labelStyle(.iconOnly)
                    .help("Summary")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 220)
        .background(WindowLevel(floating: model.settings.alwaysOnTop))
    }
}

struct CaptionRow: View {
    let line: CaptionLine
    let fontSize: Double
    let style: CaptionStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: line.heard)
                .font(style.font(size: fontSize * 0.8))
                .foregroundStyle(line.isFinal ? style.heard : style.partial)
            if !line.translation.isEmpty {
                Text(verbatim: line.translation)
                    .font(style.font(size: fontSize, weight: .medium))
                    .foregroundStyle(style.translation)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Puts the caption window above other windows (the meeting) when asked.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}
