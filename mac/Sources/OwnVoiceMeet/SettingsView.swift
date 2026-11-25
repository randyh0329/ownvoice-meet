// Settings: what to listen to and with what, how to translate and into which Chinese, the keys,
// and how the window looks (including the interface language).

import AppKit
import OwnVoiceCore
import SwiftUI
import Translation

enum SettingsTab: Hashable {
    case listen, summary, keys, appearance, usage, about
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("Listen & Translate", systemImage: "waveform", value: SettingsTab.listen) { ListenTranslateTab() }
            Tab("Summary & Saving", systemImage: "square.and.arrow.down", value: SettingsTab.summary) { SummarySavingTab() }
            Tab("API Keys", systemImage: "key", value: SettingsTab.keys) { KeysTab() }
            Tab("Appearance", systemImage: "textformat.size", value: SettingsTab.appearance) { AppearanceTab() }
            Tab("Usage", systemImage: "chart.bar", value: SettingsTab.usage) { UsageTab() }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) { AboutTab() }
        }
        .frame(width: 640, height: 600)
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
                if model.settings.listen == .localWhisper {
                    TextField("Server address (up to /v1)", text: $model.settings.whisperURL)
                    TextField("Model", text: $model.settings.whisperModel)
                }
                if model.settings.listen.isCloud {
                    Toggle("Pause recognition while the room is quiet (nothing is billed)", isOn: $model.settings.pauseWhenQuiet)
                }
                Picker("Stop listening after quiet for", selection: $model.settings.stopAfterQuietMinutes) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 30, 60], id: \.self) { m in Text(verbatim: String(localized: "\(String(m)) minutes")).tag(m) }
                }
            }
            Section("Translate") {
                if model.settings.listen == .geminiLiveTranslate || model.settings.listen == .recordOnly {
                    Text("Captions do not use the translation model with this recognition; replies and the summary still do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if model.settings.translate == .localServer {
                    TextField("Server address (up to /v1)", text: $model.settings.localServerURL)
                    TextField("Model", text: $model.settings.localServerModel)
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
            GemmaSection()
            SpeakersSection()
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

/// A local model on this Mac: which one, what is there, and one button for whatever is missing.
private struct GemmaSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var setup = model.gemma
        Section("Local model on this Mac (free, offline)") {
            Picker("Model", selection: $setup.model) {
                ForEach(LocalModel.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            Text(verbatim: setup.message.isEmpty ? String(localized: "Checking…") : setup.message)
            if let p = setup.progress {
                ProgressView(value: p)
            }
            HStack {
                Button("Set Up") {
                    Task {
                        await setup.setUp()
                        if setup.state == .ready { model.settings.translate = setup.model.option }
                    }
                }
                .disabled(setup.state == .working || setup.state == .checking || setup.state == .ready)
                Button("Use It") { model.settings.translate = setup.model.option }
                    .disabled(setup.state != .ready || model.settings.translate == setup.model.option)
                Button("Check Again") { Task { await setup.check() } }
                    .disabled(setup.state == .working)
                if setup.state == .working { ProgressView().controlSize(.small) }
            }
            Text("One click installs what is missing: Ollama from ollama.com (about 230 MB, signature checked) and the chosen model. TranslateGemma only translates captions (replies and the summary then use another model); Gemma 4 also does replies and summaries. Text never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await setup.check() }
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
                Picker("Model", selection: $model.settings.liveSummaryModel) {
                    ForEach(SummaryModelChoice.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text("Every few minutes during the meeting: a fast, cheap model is enough. \"Same as replies\" is the one chosen under Translation, or with Apple Translation or TranslateGemma the first with a key, else Gemma 4.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Meeting summary") {
                Toggle("Summarize the whole meeting when it ends", isOn: $model.settings.meetingSummaryOnStop)
                Picker("Model", selection: $model.settings.meetingSummaryModel) {
                    ForEach(SummaryModelChoice.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text("Once, at the end: the whole transcript (with speakers and translations) goes to this model for minutes — key points, decisions, action items, open questions — shown in the Summary window and saved as minutes.md. A strong cloud model such as Claude Opus 5.5 does this well; an hour costs roughly US$0.10–0.50 with it. The transcript is sent to that service. You can also press Summarize Whole Meeting in the Summary window at any time.")
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
                SecureField("OpenAI API key", text: $model.openAIKeyDraft)
                SecureField("Your own server's key (if it needs one)", text: $model.localKeyDraft)
            } footer: {
                Text("Kept in your login Keychain, never in a file. Apple recognition, Apple Translation and Gemma need no key.")
            }
            HStack {
                Spacer()
                if model.keysSaved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save Keys") {
                    Keychain.set("gemini", model.geminiKeyDraft)
                    Keychain.set("anthropic", model.anthropicKeyDraft)
                    Keychain.set("openai", model.openAIKeyDraft)
                    Keychain.set("local", model.localKeyDraft)
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

    /// A color setting (stored as "#RRGGBB") for a ColorPicker.
    private func hexBinding(_ key: WritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: model.settings[keyPath: key]) }, set: { model.settings[keyPath: key] = $0.hex })
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Captions") {
                Slider(value: $model.settings.fontSize, in: 14...40, step: 1) {
                    Text("Text size")
                }
                Toggle("Keep Window on Top", isOn: $model.settings.alwaysOnTop)
            }
            Section("Colors") {
                Picker("Theme", selection: $model.settings.captionTheme) {
                    ForEach(CaptionTheme.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                if model.settings.captionTheme == .custom {
                    ColorPicker("What was said", selection: hexBinding(\.customHeard), supportsOpacity: false)
                    ColorPicker("Chinese", selection: hexBinding(\.customTranslation), supportsOpacity: false)
                    ColorPicker("Background", selection: hexBinding(\.customBackground), supportsOpacity: false)
                    Toggle("Monospaced font", isOn: $model.settings.customMonospaced)
                }
                ThemePreview(style: CaptionStyle.of(model.settings), fontSize: model.settings.fontSize)
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

/// Two caption lines in the chosen colors: one finished and translated, one still being spoken.
private struct ThemePreview: View {
    let style: CaptionStyle
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionRow(line: CaptionLine(id: 1, heard: "Welcome to the panel on digital libraries.", translation: "歡迎來到數位圖書館座談會。", isFinal: true), fontSize: min(fontSize, 22), style: style)
            CaptionRow(line: CaptionLine(id: 2, heard: "Our first panelist will talk about", isFinal: false), fontSize: min(fontSize, 22), style: style)
        }
        .padding(12)
        .background(style.background ?? Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Estimated cost at list prices, for this session and this month, per service.
private struct UsageTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            UsageSection(title: String(localized: "This session"), book: model.sessionUsage)
            UsageSection(title: String(localized: "This month"), book: model.monthUsage)
            Section {
                Button("Reset", role: .destructive) { model.resetUsage() }
            } footer: {
                Text("Estimates at the providers' list prices (checked 2026-10-17); the providers' bills are what counts. Apple, Gemma, TranslateGemma and your own servers cost nothing.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct UsageSection: View {
    let title: String
    let book: UsageBook

    static func detail(_ t: UsageTally) -> String {
        if t.audioSeconds > 0 {
            let minutes = String(format: "%.1f", t.audioSeconds / 60)
            return String(localized: "\(minutes) minutes of sound")
        }
        let requests = String(t.requests), input = String(t.tokens.input + t.tokens.cached), output = String(t.tokens.output)
        return String(localized: "\(requests) requests, \(input) tokens in, \(output) out")
    }

    var body: some View {
        Section(title) {
            let rows = book.models.sorted { $0.key < $1.key }
            if rows.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.key) { id, tally in
                LabeledContent {
                    Text(verbatim: String(format: "US$%.3f", tally.cost(id)))
                } label: {
                    Text(verbatim: id)
                    Text(verbatim: Self.detail(tally))
                }
            }
            LabeledContent(String(localized: "Total")) {
                Text(verbatim: String(format: "US$%.3f", book.total)).bold()
            }
        }
    }
}

private struct AboutTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Form {
            Section {
                LabeledContent(String(localized: "Version")) { Text(verbatim: version) }
                HStack {
                    Button("Check for Updates") { Task { await model.checkForUpdates() } }
                    if let url = model.updateURL {
                        Button("Open the Download Page") { NSWorkspace.shared.open(url) }
                    }
                }
                if !model.updateMessage.isEmpty { Text(verbatim: model.updateMessage) }
            } footer: {
                Text("Checking asks GitHub (api.github.com) for this fork's latest release, only when you press the button.")
            }
            Section("Sources") {
                Link("This fork: randyh0329/ownvoice-meet", destination: URL(string: "https://github.com/randyh0329/ownvoice-meet")!)
                Link("Original project by Zaious: Zaious/ownvoice-meet", destination: URL(string: "https://github.com/Zaious/ownvoice-meet")!)
                Text("Apache License 2.0. The changes in this fork are not the original author's. Translations are made on the spot by the model you choose: read them before you say them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The people in the meeting: names to label lines with (⌥1…⌥9 picks who is speaking now).
private struct SpeakersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Speakers") {
            Toggle("Tell speakers apart by voice (on this Mac)", isOn: $model.settings.autoSpeakers)
                .onChange(of: model.settings.autoSpeakers) { _, on in
                    if on, !model.speakerModels.ready { Task { await model.speakerModels.download() } }
                }
            if model.settings.autoSpeakers {
                HStack {
                    if model.speakerModels.downloading { ProgressView().controlSize(.small) }
                    Text(verbatim: model.speakerModels.ready ? String(localized: "✓ The voice models are on this Mac.") : (model.speakerModels.message.isEmpty ? String(localized: "The voice models (about 32 MB) are downloaded once.") : model.speakerModels.message))
                        .font(.caption)
                    if !model.speakerModels.ready && !model.speakerModels.downloading {
                        Button("Download") { Task { await model.speakerModels.download() } }
                    }
                }
                Text("New voices become Speaker 1, 2, 3… on their own. Right-click one line of a voice and choose a name: every line of that voice, earlier and later, takes it. Works with every recognition; free, nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.settings.speakerNames.indices), id: \.self) { i in
                HStack {
                    Text(verbatim: "⌥\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
                    TextField("Name", text: Binding(
                        get: { i < model.settings.speakerNames.count ? model.settings.speakerNames[i] : "" },
                        set: { if i < model.settings.speakerNames.count { model.settings.speakerNames[i] = $0 } }
                    ))
                    Button("Remove", systemImage: "minus.circle") { model.removeSpeaker(at: i) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Speaker…") { model.askAddSpeaker() }
            Text("Name the people in the meeting; pick who is speaking from the caption bar or the Speaker menu (⌥1…⌥9), and right-click a line to change its speaker. Names go into the transcript and the summary. Renaming updates every line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
