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
    @State private var appleStatus = ""

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
                    if !appleStatus.isEmpty {
                        Text(verbatim: appleStatus).font(.caption)
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
        case .installed: appleStatus = String(localized: "✓ Ready: \(s.meetingLanguage) → \(target) is on this Mac.")
        case .supported: appleStatus = String(localized: "Not downloaded yet: open Language & Region → Translation Languages and download both languages.")
        default: appleStatus = String(localized: "Apple Translation does not offer this pair.")
        }
    }
}

private struct KeysTab: View {
    @State private var gemini = Keychain.get("gemini") ?? ""
    @State private var anthropic = Keychain.get("anthropic") ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("Gemini API key", text: $gemini)
                SecureField("Anthropic API key", text: $anthropic)
            } footer: {
                Text("Kept in your login Keychain, never in a file. Apple recognition, Apple Translation and Gemma need no key.")
            }
            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save Keys") {
                    Keychain.set("gemini", gemini)
                    Keychain.set("anthropic", anthropic)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceTab: View {
    @Environment(AppModel.self) private var model
    @State private var language = InterfaceLanguage.current
    @State private var languageChanged = false

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
                Picker("Language", selection: $language) {
                    ForEach(InterfaceLanguage.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .onChange(of: language) { _, new in
                    new.apply()
                    languageChanged = true
                }
                if languageChanged {
                    Text("Quit and reopen OwnVoice Meet to use the new language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
