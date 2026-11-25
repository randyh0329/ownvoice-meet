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
            Tab("API Keys", systemImage: "key") { KeysTab() }
            Tab("Appearance", systemImage: "textformat.size") { AppearanceTab() }
        }
        .frame(width: 560, height: 520)
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
