// The windows around the captions: Reply (type Chinese, read the words aloud), Script (the
// prepared bilingual script, with 補對照) and Summary (the main points so far).

import AppKit
import OwnVoiceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reply

struct ReplyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.replyChinese.isEmpty {
                        Text("Type what you want to say in Chinese below. The sentence to read aloud appears here, in large text.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: model.replyChinese)
                            .foregroundStyle(.secondary)
                        Text(verbatim: model.replyText.isEmpty ? "…" : model.replyText)
                            .font(.system(size: model.settings.fontSize * 1.5, weight: .semibold))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("What do you want to say? (Chinese)", text: $model.replyInput, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.sendReply() }
            HStack {
                Text("Return sends. The language to read is chosen in Settings (I speak).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.replyWorking { ProgressView().controlSize(.small) }
                Button("Send") { model.sendReply() }
                    .disabled(model.replyInput.trimmingCharacters(in: .whitespaces).isEmpty || model.replyWorking)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 280)
    }
}

// MARK: - Script

struct ScriptView: View {
    @Environment(AppModel.self) private var model

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
                Spacer()
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
                TextEditor(text: $model.script)
                    .font(.body.monospaced())
                    .padding(6)
            } else {
                ScriptPreview(items: Script.parse(model.script), fontSize: model.settings.fontSize)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        model.script = text
        model.scriptEditing = false
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
            Text(verbatim: title).font(.title2.bold()).padding(.top, 8).id("section-\(index)")
        case let .sub(title):
            Text(verbatim: title).font(.headline).padding(.top, 4)
        case let .cue(text):
            Text(verbatim: text).italic().foregroundStyle(.secondary)
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

struct SummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(verbatim: model.summary.isEmpty ? String(localized: "The main points appear here every few minutes while listening (Settings → Summary & Saving).") : model.summary)
                    .font(.system(size: model.settings.fontSize * 0.85))
                    .foregroundStyle(model.summary.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.summaryError.isEmpty {
                Text(verbatim: model.summaryError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(verbatim: model.summaryUpdated).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.summaryWorking { ProgressView().controlSize(.small) }
                Button("Update Now") { Task { await model.updateSummary(force: true) } }
                    .disabled(model.summaryWorking || model.record == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 260)
    }
}
