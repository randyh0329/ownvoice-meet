// Settings: what to listen to and with what, how to translate and into which Chinese, the keys,
// and how the window looks (including the interface language).

import AppKit
import OwnVoiceCore
import SwiftUI
import Translation

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Listen & Translate", systemImage: "waveform") { ListenTranslateTab() }
            Tab("Summary & Saving", systemImage: "square.and.arrow.down") { SummarySavingTab() }
            Tab("API Keys", systemImage: "key") { KeysTab() }
            Tab("Appearance", systemImage: "textformat.size") { AppearanceTab() }
        }
        .frame(width: 600, height: 560)
    }
}

private struct ListenTranslateTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Listen") {
                Picker("Sound", selection: $model.settings.input) {
                    ForEach(AudioInput.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Picker("Recognition", selection: $model.settings.listen) {
                    ForEach(ListenOption.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text(verbatim: model.settings.listen.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Meeting language", selection: $model.settings.meetingLanguage) {
                    ForEach(MeetingLanguage.all) { Text(verbatim: $0.name).tag($0.code) }
                }
            }
            Section("Translate") {
                Picker("Translation", selection: $model.settings.translate) {
                    ForEach(TranslateOption.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text(verbatim: model.settings.translate.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Chinese", selection: $model.settings.chinese) {
                    ForEach(ChineseVariant.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Picker("I speak", selection: $model.settings.speakLanguage) {
                    ForEach(SpeakLanguage.all) { Text(verbatim: $0.name).tag($0.code) }
                }
                .help("Replies and Fill In Missing Halves write in this language.")
                if model.settings.translate == .apple {
                    HStack {
                        Button("Check Apple Translation") { Task { await checkApple() } }
                        Button("Open Language & Region") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                        }
                    }
                    if !model.appleCheck.isEmpty {
                        Text(verbatim: model.appleCheck).font(.caption)
                    }
                }
            }
            Section("Glossary") {
                TextEditor(text: $model.settings.glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                Text("One term per line: 中文 = English. Used by Claude, Gemini and Gemma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func checkApple() async {
        let s = model.settings
        let source = Locale.Language(identifier: s.meetingLanguage.isEmpty ? "en" : s.meetingLanguage)
        let (target, status) = await AppleTranslator.target(from: source, chinese: s.chinese)
        switch status {
        case .installed: model.appleCheck = String(localized: "✓ Ready: \(s.meetingLanguage) → \(target) is on this Mac.")
        case .supported: model.appleCheck = String(localized: "Not downloaded yet: open Language & Region → Translation Languages and download both languages.")
        default: model.appleCheck = String(localized: "Apple Translation does not offer this pair.")
        }
    }
}

private struct SummarySavingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Live summary") {
                Picker("Update every", selection: $model.settings.summaryEveryMinutes) {
                    Text("Only when asked").tag(0)
                    ForEach([2, 5, 10, 15], id: \.self) { m in Text(verbatim: String(localized: "\(String(m)) minutes")).tag(m) }
                }
                Text("Uses the text model: the one chosen under Translation, or with Apple Translation the first with a key (Claude, Gemini), else Gemma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Saving") {
                Picker("Keep", selection: $model.settings.saveMode) {
                    ForEach(SaveMode.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                LabeledContent("Folder") {
                    Text(verbatim: model.settings.saveFolderURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { chooseFolder() }
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.settings.saveFolderURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.settings.saveFolderURL)
                    }
                    if !model.settings.saveFolder.isEmpty {
                        Button("Use Documents") { model.settings.saveFolder = "" }
                    }
                }
                Text("Each session gets a folder with transcript.md and summary.md, and recording.m4a if chosen. Other people's voices are kept: check that everyone agrees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.settings.saveFolder = url.path }
    }
}

private struct KeysTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SecureField("Gemini API key", text: $model.geminiKeyDraft)
                SecureField("Anthropic API key", text: $model.anthropicKeyDraft)
            } footer: {
                Text("Kept in your login Keychain, never in a file. Apple recognition, Apple Translation and Gemma need no key.")
            }
            HStack {
                Spacer()
                if model.keysSaved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save Keys") {
                    Keychain.set("gemini", model.geminiKeyDraft)
                    Keychain.set("anthropic", model.anthropicKeyDraft)
                    model.keysSaved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Captions") {
                Slider(value: $model.settings.fontSize, in: 14...40, step: 1) {
                    Text("Text size")
                }
                Toggle("Keep Window on Top", isOn: $model.settings.alwaysOnTop)
            }
            Section("Interface") {
                Picker("Language", selection: $model.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                if model.languageChanged {
                    Text("Quit and reopen OwnVoice Meet to use the new language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
