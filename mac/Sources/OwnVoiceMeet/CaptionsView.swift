// The caption window: each line as heard (gray while the sentence goes on) with its Chinese under
// it, newest at the bottom (or only the translations); a bar with Start/Stop, the status, text size,
// background, click-through and Settings.

import AppKit
import OwnVoiceCore
import SwiftUI

struct CaptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        let style = CaptionStyle.of(model.settings)
        let opacity = model.settings.captionsOpacity
        let clickThrough = WindowControl.shared.clickThrough
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.book.lines.isEmpty {
                            Text("Captions appear here: what is said, and its Chinese under it.")
                                .font(style.font(size: 14))
                                .foregroundStyle(style.partial)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !model.isListening && !model.demoRunning {
                                Button("Play Demo", systemImage: "play.circle") { model.startDemo() }
                                    .disabled(model.finishing)
                                    .help("A short sample exchange, to see what each window does: no sound, keys or network, nothing saved.")
                            }
                        }
                        ForEach(model.book.lines) { line in
                            CaptionRow(line: line, fontSize: model.settings.fontSize, style: style, speaker: model.speakerName(line.speaker), translationOnly: model.settings.translationOnly)
                                .id(line.id)
                                .contextMenu { SpeakerChoices(selected: line.speaker) { model.assignSpeaker($0, to: line.id) } }
                        }
                    }
                    .padding(16)
                }
                .fadedBackground(opacity, style.background ?? Color(nsColor: .windowBackgroundColor))
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
                if let tag = model.updateAvailable {
                    Button {
                        if let url = model.updateURL { NSWorkspace.shared.open(url) }
                        model.dismissAvailableUpdate()
                    } label: {
                        Label(String(localized: "Update available: \(tag)"), systemImage: "arrow.down.circle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                    .help("Opens the release page on GitHub.")
                }
                Spacer()
                LookControls(size: $model.settings.fontSize, opacity: $model.settings.captionsOpacity)
                Toggle(isOn: $model.settings.translationOnly) {
                    Label("Translation Only", systemImage: "translate")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Translation Only: hide what was heard and show only the translations")
                Button("Click Through Captions", systemImage: "cursorarrow.rays") { WindowControl.shared.clickThrough = true }
                    .labelStyle(.iconOnly)
                    .help("Click through: clicks go to the meeting under the captions. To click the captions again, press ⌃⇧F8 or use OwnVoice Meet in the menu bar.")
                Menu {
                    SpeakerChoices(selected: model.currentSpeaker) { model.setCurrentSpeaker($0) }
                    Divider()
                    Button("Add Speaker…") { model.askAddSpeaker() }
                    Button("Reset Speakers…") { model.speakerResetPrompt = true }
                        .disabled(model.settings.speakerNames.isEmpty)
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
            .fadedBackground(opacity)
        }
        .overlay(alignment: .top) {
            if clickThrough {
                Text("Clicks go to the window underneath. Press ⌃⇧F8, or use OwnVoice Meet in the menu bar, to click the captions again.")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .frame(minWidth: 600, minHeight: 220)
        .onAppear { model.captionsUndo = undoManager }
        .onChange(of: undoManager) { _, new in model.captionsUndo = new }
        .alert("Add speaker", isPresented: Bindable(model).speakerPrompt) {
            TextField("Name", text: Bindable(model).speakerDraft)
            Button("Add") { model.confirmAddSpeaker() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New lines get this name until you choose another.")
        }
        .alert("Reset speakers?", isPresented: Bindable(model).speakerResetPrompt) {
            Button("Reset Speakers", role: .destructive) { model.resetSpeakers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every speaker name is removed, and no line keeps a speaker, in the captions or in this session's transcript. New voices start again from Speaker 1. Undo in the caption window brings the names back.")
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
        .windowTraits("captions", ignoresMouse: clickThrough)
    }
}

struct CaptionRow: View {
    let line: CaptionLine
    let fontSize: Double
    let style: CaptionStyle
    var speaker: String? = nil
    /// Only the translation; a line still without one shows a small "…", so speech is seen coming.
    var translationOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if translationOnly {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    speakerLabel
                    if line.translation.isEmpty {
                        Text(verbatim: "…")
                            .font(style.font(size: fontSize * 0.8))
                            .foregroundStyle(style.partial)
                    } else {
                        Text(verbatim: line.translation)
                            .font(style.font(size: fontSize, weight: .medium))
                            .foregroundStyle(style.translation)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    speakerLabel
                    Text(verbatim: line.heard)
                        .font(style.font(size: fontSize * 0.8))
                        .foregroundStyle(line.isFinal ? style.heard : style.partial)
                }
            }
            if !translationOnly, !line.translation.isEmpty {
                Text(verbatim: line.translation)
                    .font(style.font(size: fontSize, weight: .medium))
                    .foregroundStyle(style.translation)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if let speaker {
            Text(verbatim: speaker + "：")
                .font(style.font(size: fontSize * 0.8, weight: .bold))
                .foregroundStyle(style.translation)
        }
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
