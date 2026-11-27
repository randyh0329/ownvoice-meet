// The windows around the captions: Reply (type Chinese, read the words aloud), Script (the
// prepared bilingual script, with 補對照) and Summary (the main points so far). Each has its own
// text size and background (A− / A+ and the slider), and is kept out of screen sharing if asked.

import AppKit
import OwnVoiceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reply

struct ReplyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let style = CaptionStyle.of(model.settings)
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.replyChinese.isEmpty {
                        Text("Type what you want to say in Chinese below. The sentence to read aloud appears here, in large text.")
                            .font(style.font(size: 14))
                            .foregroundStyle(style.partial)
                    } else {
                        Text(verbatim: model.replyChinese)
                            .font(style.font(size: model.settings.replyFontSize * 0.8))
                            .foregroundStyle(style.translation)
                        Text(verbatim: model.replyText.isEmpty ? "…" : model.replyText)
                            .font(style.font(size: model.settings.replyFontSize * 1.5, weight: .semibold))
                            .foregroundStyle(style.heard)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background((style.background ?? .clear).opacity(model.settings.replyOpacity), in: RoundedRectangle(cornerRadius: 8))
            TextField("What do you want to say? (Chinese)", text: $model.replyInput, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.sendReply() }
            HStack {
                Text("Return sends. The language to read is chosen in Settings (I speak).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                LookControls(size: $model.settings.replyFontSize, opacity: $model.settings.replyOpacity)
                if model.replyWorking { ProgressView().controlSize(.small) }
                Button("Send") { model.sendReply() }
                    .disabled(model.replyInput.trimmingCharacters(in: .whitespaces).isEmpty || model.replyWorking)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 280)
        .fadedBackground(model.settings.replyOpacity)
        .windowTraits("reply", hiddenFromCapture: model.settings.hideFromCapture)
    }
}

// MARK: - Script

struct ScriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.scriptEditing) { Label("Edit", systemImage: "pencil") }
                    .toggleStyle(.button)
                Button("Open…", systemImage: "folder") { openScript() }
                Button("Insert Template", systemImage: "doc.badge.plus") { model.insertTemplate() }
                Button("Fill In Missing Halves", systemImage: "character.bubble") { Task { await model.fillScript() } }
                    .disabled(model.scriptWorking || model.script.isEmpty)
                    .help("補對照: a line without its meaning gets its Chinese; a line written in Chinese gets the words to read aloud.")
                if model.scriptWorking { ProgressView().controlSize(.small) }
                if model.scriptEditing {
                    Button("Format Help", systemImage: "questionmark.circle") { model.scriptFormatHelp = true }
                        .popover(isPresented: $model.scriptFormatHelp, arrowEdge: .bottom) { ScriptFormatHelp() }
                }
                Spacer()
                LookControls(size: $model.settings.scriptFontSize, opacity: $model.settings.scriptOpacity)
            }
            .padding(8)
            if !model.scriptMessage.isEmpty {
                Text(verbatim: model.scriptMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            Divider()
            if model.scriptEditing {
                // The text and, beside it, the script as it will look, updated as you type.
                HSplitView {
                    TextEditor(text: $model.script)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minWidth: 220)
                    ScriptPreview(items: Script.parse(model.script), fontSize: model.settings.scriptFontSize * 0.8)
                        .frame(minWidth: 200)
                }
                let missing = Script.plan(model.script).count
                if missing > 0 {
                    Divider()
                    Text(verbatim: missing == 1
                        ? String(localized: "1 line has no translation yet — Fill In Missing Halves adds it.")
                        : String(localized: "\(String(missing)) lines have no translation yet — Fill In Missing Halves adds them."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            } else {
                ScriptPreview(items: Script.parse(model.script), fontSize: model.settings.scriptFontSize)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .fadedBackground(model.settings.scriptOpacity)
        .windowTraits("script", hiddenFromCapture: model.settings.hideFromCapture)
        .onAppear { model.scriptUndo = undoManager }
        .onChange(of: undoManager) { _, new in model.scriptUndo = new }
    }

    private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        model.setScript(text, action: String(localized: "Open Script"))
        model.scriptEditing = false
    }
}

/// Format Help: what each kind of line in a script means.
private struct ScriptFormatHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Script format").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                row(Text(String(localized: "# Title")), Text("A tab (Opening, Demo, Q&A: name them as you like)"))
                row(Text(String(localized: "## Subheading")), Text("A small heading inside a tab"))
                row(Text(String(localized: "! Cue")), Text("A gray cue, not read aloud (such as “switch to slide 2”)"))
                row(Text(String(localized: "Q: Question")), Text("A question prepared in advance"))
                row(Text(String(localized: "A plain line")), Text("A line to read aloud (Chinese works too: Fill In Missing Halves turns it into the language you speak)"))
                row(Text(String(localized: "> Chinese")), Text("The Chinese meaning of the line above"))
                row(Text(String(localized: "```copy:name … ```")), Text("A block to copy with one click (links, commands)"))
            }
            Text("A line written another way still shows. While you edit, the bottom of the window counts the lines that have no translation yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ example: Text, _ meaning: Text) -> some View {
        GridRow {
            example.font(.body.monospaced())
            meaning.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ScriptPreview: View {
    let items: [ScriptItem]
    let fontSize: Double

    var body: some View {
        let sections = Script.sections(items)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if sections.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(sections.enumerated()), id: \.offset) { index, title in
                                Button(title) { withAnimation { proxy.scrollTo("section-\(index)", anchor: .top) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(8)
                    }
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty {
                            Text("No script yet. Press Edit to write one, Open… to read a .md file, or Insert Template to start from an example. Write only one language: Fill In Missing Halves adds the other.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            ScriptItemView(item: item, fontSize: fontSize)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

private struct ScriptItemView: View {
    let item: ScriptItem
    let fontSize: Double

    var body: some View {
        switch item {
        case let .section(title, index):
            Text(verbatim: title).font(.system(size: fontSize * 1.2, weight: .bold)).padding(.top, 8).id("section-\(index)")
        case let .sub(title):
            Text(verbatim: title).font(.system(size: fontSize * 0.9, weight: .semibold)).padding(.top, 4)
        case let .cue(text):
            Text(verbatim: text).font(.system(size: fontSize * 0.75)).italic().foregroundStyle(.secondary)
        case let .gloss(text):
            Text(verbatim: text).font(.system(size: fontSize * 0.75)).foregroundStyle(.secondary)
        case let .question(text):
            Text(verbatim: "Q: " + text).font(.system(size: fontSize, weight: .semibold))
        case let .line(text):
            Text(verbatim: text).font(.system(size: fontSize))
        case let .copy(name, text):
            CopyBlock(name: name, text: text)
        }
    }
}

private struct CopyBlock: View {
    let name: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            Text(verbatim: text).font(.body.monospaced())
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Summary

enum SummaryPane: Hashable {
    case live, meeting
}

struct SummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Summary", selection: $model.summaryPane) {
                    Text("Live summary").tag(SummaryPane.live)
                    Text("Meeting summary").tag(SummaryPane.meeting)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LookControls(size: $model.settings.summaryFontSize, opacity: $model.settings.summaryOpacity)
            }
            if model.summaryPane == .live { live } else { meeting }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 280)
        .fadedBackground(model.settings.summaryOpacity)
        .windowTraits("summary", hiddenFromCapture: model.settings.hideFromCapture)
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(verbatim: model.summary.isEmpty ? placeholder : model.summary)
                    .font(.system(size: model.settings.summaryFontSize * 0.85))
                    .foregroundStyle(model.summary.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.summaryError.isEmpty {
                Text(verbatim: model.summaryError).font(.caption).foregroundStyle(.red)
            }
            // The notes on a line of their own, so the buttons never squeeze them.
            VStack(alignment: .leading, spacing: 2) {
                if !model.summaryUpdated.isEmpty {
                    Text(verbatim: model.summaryUpdated)
                }
                if model.nextSummaryAt != nil {
                    // Refreshed every 5 s (as often as the update is checked for), so the note
                    // keeps up without anything else changing.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        if let note = nextUpdateNote {
                            Text(verbatim: note)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                intervalMenu
                if model.summaryWorking { ProgressView().controlSize(.small) }
                Button("Update Now") { Task { await model.updateSummary(force: true) } }
                    .disabled(model.summaryWorking || model.record == nil)
            }
        }
    }

    /// nil: nothing worth saying (not scheduled, or an update is being written right now).
    private var nextUpdateNote: String? {
        guard let next = model.nextSummaryAt, !model.summaryWorking else { return nil }
        let minutes = Int((next.timeIntervalSinceNow / 60).rounded(.up))
        if minutes > 0 { return String(localized: "Next update in about \(String(minutes)) min") }
        let missing = model.summaryLinesMissing
        if missing == 1 { return String(localized: "Next update: when one more line is in") }
        if missing > 1 { return String(localized: "Next update: when \(String(missing)) more lines are in") }
        return String(localized: "Next update: any moment")
    }

    private static let intervalPresets = [1, 2, 3, 5, 10, 15, 30]

    /// The live summary's interval, changeable during the meeting.
    private var intervalMenu: some View {
        @Bindable var model = model
        // The interval set in Settings is listed even if it is not a preset (and while updates
        // are off), so it can always be chosen again.
        let minutes = Set(Self.intervalPresets + [model.settings.summaryMinutes]).sorted()
        return Menu {
            Picker("Update", selection: $model.summaryInterval) {
                Text("Only When I Press Update Now").tag(nil as Int?)
                Divider()
                ForEach(minutes, id: \.self) { m in
                    Text(verbatim: AppSettings.everyMinutes(m)).tag(Optional(m))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.summaryInterval.map(AppSettings.everyMinutes) ?? String(localized: "Only when asked"), systemImage: "clock.arrow.circlepath")
        }
        .fixedSize()
        .help("How often the live summary brings itself up to date")
    }

    private var placeholder: String {
        switch model.summaryInterval {
        case nil: String(localized: "The main points appear here when you press Update Now.")
        case 1: String(localized: "The main points appear here every minute while listening.")
        case let m?: String(localized: "The main points appear here every \(String(m)) minutes while listening.")
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(verbatim: model.minutes.isEmpty ? String(localized: "When the meeting is over, the whole transcript can go to a stronger model for minutes: key points, decisions, action items and open questions. Choose the model in Settings → Summary & Saving.") : model.minutes)
                    .font(.system(size: model.settings.summaryFontSize * 0.8))
                    .foregroundStyle(model.minutes.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(verbatim: model.minutesNote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.minutesWorking { ProgressView().controlSize(.small) }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.minutes, forType: .string)
                }
                .disabled(model.minutes.isEmpty)
                Button("Summarize Whole Meeting") { Task { await model.summarizeMeeting() } }
                    .disabled(model.minutesWorking || (model.record == nil && model.lastRecord == nil))
            }
        }
    }
}
