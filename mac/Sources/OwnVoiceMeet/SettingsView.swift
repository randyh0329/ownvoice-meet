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
                if model.settings.input == .microphone { MicrophoneRows() }
                Picker("Recognition", selection: $model.settings.listen) {
                    ForEach(ListenOption.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text(verbatim: model.settings.listen.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Meeting language", selection: $model.settings.meetingLanguage) {
                    ForEach(MeetingLanguage.all) { Text(verbatim: $0.name).tag($0.code) }
                }
                if model.settings.meetingLanguage.isEmpty && model.settings.listen == .appleSpeech {
                    Text("Apple recognition cannot detect the language: it listens for English (US).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            if model.settings.listen == .localSherpa {
                LocalSpeechSection()
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
                // Only recognition with gray text while someone speaks has a sentence to translate early.
                if [ListenOption.appleSpeech, .geminiLive, .openaiLive].contains(model.settings.listen) {
                    Toggle("Translate long sentences before they end", isOn: $model.settings.earlyTranslation)
                    Text("While a long sentence is still being spoken, its Chinese starts to appear; the full translation takes over when the sentence ends. With a paid translation model this costs a few extra cents an hour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Chinese", selection: $model.settings.chinese) {
                    ForEach(ChineseVariant.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Picker("I speak", selection: $model.settings.speakLanguage) {
                    ForEach(SpeakLanguage.all) { Text(verbatim: $0.name).tag($0.code) }
                }
                .help("Replies and Fill In Missing Halves write in this language.")
                // Also when only a summary uses it, so it can be filled in at all.
                if model.settings.translate == .localServer || model.settings.liveSummaryModel == .local || model.settings.meetingSummaryModel == .local {
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
            ChatGPTSection()
            GemmaSection()
            SpeakersSection()
            Section("Glossary") {
                TextEditor(text: $model.settings.glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                Text("One term per line: 中文 = English. Used by Claude, Gemini and Gemma, and also given to recognition, so names and product terms are heard right.")
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
                        // Taken for translation only if a local model was already the choice
                        // (otherwise Use It does it), so setting one up for replies keeps Claude, say.
                        if setup.state == .ready, model.settings.translate.ollamaModel != nil {
                            model.settings.translate = setup.model.option
                        }
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
        .task {
            // The section follows the local model chosen under Translation, not the one at launch.
            if let chosen = model.settings.translate.ollamaModel { setup.model = chosen }
            await setup.check()
        }
        .onChange(of: model.settings.translate) { _, new in
            if let chosen = new.ollamaModel { setup.model = chosen }
        }
    }
}

private struct SummarySavingTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Live summary") {
                Toggle("Update automatically while listening", isOn: $model.settings.summaryAuto)
                if model.settings.summaryAuto {
                    Stepper(value: $model.settings.summaryMinutes, in: AppSettings.summaryMinutesRange) {
                        Text(verbatim: AppSettings.everyMinutes(model.settings.summaryMinutes))
                    }
                    Text(verbatim: String(localized: "Counted from the last update, and only once there are at least \(String(AppModel.summaryMinLines)) new lines, so a quiet stretch is skipped. The last lines are summarized when listening stops."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nothing is summarized until you press Update Now in the Summary window, not even when listening stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("During a meeting, Update Now in the Summary window brings the summary up to date at once, and the interval can be changed there too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $model.settings.liveSummaryModel) {
                    ForEach(SummaryModelChoice.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Text("A fast, cheap model is enough. \"Same as replies\" is the one chosen under Translation, or with Apple Translation or TranslateGemma the first with a key, else Gemma 4.")
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
            AgendaSection()
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
                Text("Each session gets a folder with transcript.md and summary.md, and for each segment its own transcript (01-name.md) and, if chosen, its own recording (01-name.m4a). Other people's voices are kept: check that everyone agrees.")
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

/// Under Sound, for a talk in the room: which microphone, its gain, and the Microphone Check.
private struct MicrophoneRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let check = model.micCheck
        let devices = InputDevices.all()
        Picker("Microphone", selection: $model.settings.micDevice) {
            Text("System default").tag("")
            ForEach(devices) { Text(verbatim: $0.name).tag($0.uid) }
            // One chosen before and unplugged now stays chosen (the default is used meanwhile).
            if !model.settings.micDevice.isEmpty, !devices.contains(where: { $0.uid == model.settings.micDevice }) {
                Text("Not connected (the default is used)").tag(model.settings.micDevice)
            }
        }
        Picker("Gain", selection: $model.settings.micGain) {
            ForEach(MicLevel.gains, id: \.self) { Text(verbatim: Self.gainLabel($0)).tag($0) }
        }
        HStack {
            Button("Microphone Check (6 s)") {
                Task { await check.run(device: model.settings.micDevice, gain: model.settings.micGain) }
            }
            .disabled(check.running || model.isListening)
            if check.running {
                ProgressView(value: check.level)
                    .frame(width: 100)
            }
        }
        if !check.result.isEmpty {
            Text(verbatim: check.result)
                .font(.caption)
        }
        Text("Check while the speaker or the room is talking: it uses the microphone and gain above. Raise the gain when you sit far from the speaker.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// "1× (as it comes)", "2×"…
    private static func gainLabel(_ gain: Double) -> String {
        let times = String(Int(gain))
        return gain == 1 ? String(localized: "1× (as it comes)") : String(localized: "\(times)×")
    }
}

/// The day's segments by name, taken in turn by New Segment.
private struct AgendaSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Agenda") {
            TextEditor(text: $model.settings.agenda)
                .frame(minHeight: 70)
            Text("Optional: one segment name per line, such as the day's sessions. Listening starts with the first; New Segment takes the next. Click the segment's name in the caption window to rename it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        // "Saved" is about what the fields show: editing one takes it away.
        .onChange(of: [model.geminiKeyDraft, model.anthropicKeyDraft, model.openAIKeyDraft, model.localKeyDraft]) { _, _ in
            model.keysSaved = false
        }
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
                Slider(value: $model.settings.fontSize, in: WindowLook.textRange, step: 1) {
                    Text("Text size")
                }
                Toggle("Keep Window on Top", isOn: $model.settings.alwaysOnTop)
                Toggle("Translation Only", isOn: $model.settings.translationOnly)
                Text("Each window has its own A− / A+ for the text size and a slider that fades its background (the text stays solid).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Screen sharing") {
                Toggle("Hide the Reply, Script and Summary windows when the screen is shared, recorded or captured", isOn: $model.settings.hideFromCapture)
                Text("The others in the meeting don't see what you are about to say. The captions window stays visible. On macOS 15 and later, apps that capture the screen with Apple's newer ScreenCaptureKit (as many recent meeting and recording apps do) may still show these windows: check with a test share before relying on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ShortcutsSection()
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

/// The shortcuts that work while another app (the meeting) is in front.
private struct ShortcutsSection: View {
    var body: some View {
        let taken = WindowControl.shared.takenShortcuts
        Section("Shortcuts from any app") {
            LabeledContent {
                Text(verbatim: GlobalShortcut.reply.symbol).monospaced()
            } label: {
                Text("Type a reply: the Reply window, ready for typing")
            }
            LabeledContent {
                Text(verbatim: GlobalShortcut.newSegment.symbol).monospaced()
            } label: {
                Text("Start a new segment now, with the next name")
            }
            LabeledContent {
                Text(verbatim: GlobalShortcut.clickThrough.symbol).monospaced()
            } label: {
                Text("Click through the captions window, or stop")
            }
            if !taken.isEmpty {
                let list = taken.joined(separator: ", ")
                Text(verbatim: String(localized: "Another app already uses \(list): those work only while OwnVoice Meet is in front."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("They work while Zoom or another app is in front, with no extra permission. The menu bar icon also turns click-through off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
