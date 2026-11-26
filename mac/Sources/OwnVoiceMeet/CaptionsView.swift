// The caption window: each line as heard (gray while the sentence goes on) with its Chinese under
// it, newest at the bottom; a bar with Start/Stop, the status and Settings.

import AppKit
import OwnVoiceCore
import SwiftUI

struct CaptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

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
                            CaptionRow(line: line, fontSize: model.settings.fontSize, style: style, speaker: model.speakerName(line.speaker))
                                .id(line.id)
                                .contextMenu { SpeakerChoices(selected: line.speaker) { model.assignSpeaker($0, to: line.id) } }
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
                if model.isListening {
                    InputLevelBar()
                    SegmentBadge()
                }
                Text(verbatim: model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Menu {
                    SpeakerChoices(selected: model.currentSpeaker) { model.setCurrentSpeaker($0) }
                    Divider()
                    Button("Add Speaker…") { model.askAddSpeaker() }
                } label: {
                    Label(model.speakerName(model.currentSpeaker) ?? String(localized: "Speaker"), systemImage: "person.wave.2")
                }
                .fixedSize()
                .help("Who is speaking now: new lines get this name. Right-click a line to change its speaker.")
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
        .onAppear { model.captionsUndo = undoManager }
        .onChange(of: undoManager) { _, new in model.captionsUndo = new }
        .alert("Add speaker", isPresented: Bindable(model).speakerPrompt) {
            TextField("Name", text: Bindable(model).speakerDraft)
            Button("Add") { model.confirmAddSpeaker() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New lines get this name until you choose another.")
        }
        .alert("New segment", isPresented: Bindable(model).segmentPrompt) {
            TextField("Name (optional)", text: Bindable(model).segmentDraft)
            Button("Start Segment") { model.confirmSegment() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript starts a new section from here.")
        }
        .alert("Rename segment", isPresented: Bindable(model).segmentRenamePrompt) {
            TextField("Segment name", text: Bindable(model).segmentRenameDraft)
            Button("Rename") { model.confirmRenameSegment() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The segment's transcript and recording take the new name.")
        }
        .background(WindowLevel(floating: model.settings.alwaysOnTop))
    }
}

struct CaptionRow: View {
    let line: CaptionLine
    let fontSize: Double
    let style: CaptionStyle
    var speaker: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let speaker {
                    Text(verbatim: speaker + "：")
                        .font(style.font(size: fontSize * 0.8, weight: .bold))
                        .foregroundStyle(style.translation)
                }
                Text(verbatim: line.heard)
                    .font(style.font(size: fontSize * 0.8))
                    .foregroundStyle(line.isFinal ? style.heard : style.partial)
            }
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

/// How loud the sound comes in while listening, a few times a second. Its own view, so only it is
/// redrawn as the level changes.
struct InputLevelBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let level = model.inputLevel
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 44, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: 44 * level, height: 5)
            }
            .animation(.linear(duration: 0.1), value: level)
            .help("Input level")
    }
}

/// The segment going on now ("01 · Keynote"), red with a dot while the sound is recorded; a click
/// renames it.
struct SegmentBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let title = SessionFiles.segmentTitle(model.segmentNumber - 1, model.segmentName)
        let recording = model.recordingSound
        Button {
            model.askRenameSegment()
        } label: {
            Text(verbatim: recording ? "● " + title : title)
                .font(.callout.weight(.medium))
                .foregroundStyle(recording ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .help(recording ? LocalizedStringKey("Recording this segment. Click to rename it.") : LocalizedStringKey("The segment going on now. Click to rename it."))
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

/// The speaker list as menu items, with "No Speaker"; `selected` gets a check mark.
struct SpeakerChoices: View {
    @Environment(AppModel.self) private var model
    let selected: Int?
    let choose: (Int?) -> Void

    var body: some View {
        ForEach(Array(model.settings.speakerNames.indices), id: \.self) { i in
            Toggle(isOn: Binding(get: { selected == i }, set: { if $0 { choose(i) } })) {
                Text(verbatim: model.speakerName(i) ?? "")
            }
        }
        Toggle("No Speaker", isOn: Binding(get: { selected == nil }, set: { if $0 { choose(nil) } }))
    }
}
