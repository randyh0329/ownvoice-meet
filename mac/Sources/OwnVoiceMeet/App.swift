// OwnVoice Meet for the Mac: a caption window that floats over the meeting; Reply, Script and
// Summary windows around it; Settings; a menu bar item. Every word of the interface comes from
// Localizable.strings (en, zh-Hant, zh-Hans).
// No @State anywhere: with the macOS 27 SDK it is a macro whose plugin ships only with Xcode, and
// the app also builds with the Command Line Tools. State lives in AppModel (Observation's macros
// are in both).

import AppKit
import SwiftUI

@main
struct OwnVoiceMeetApp: App {
    private let model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("OwnVoice Meet", id: "captions") {
            CaptionsView().environment(model)
        }
        .defaultSize(width: 760, height: 440)
        .commands { AppCommands(model: model) }

        Window("Reply", id: "reply") {
            ReplyView().environment(model)
        }
        .defaultSize(width: 620, height: 360)

        Window("Script", id: "script") {
            ScriptView().environment(model)
        }
        .defaultSize(width: 640, height: 640)

        Window("Summary", id: "summary") {
            SummaryView().environment(model)
        }
        .defaultSize(width: 460, height: 420)

        Settings {
            SettingsView().environment(model)
        }

        // The way back from click-through (the captions window then cannot be clicked).
        MenuBarExtra("OwnVoice Meet", systemImage: "captions.bubble") {
            MenuBarMenu().environment(model)
        }
    }
}

/// Quitting while listening (or while the last session finishes) first closes the session, so the
/// recording can be played and the transcript, summary and minutes are written.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotKeys.registerAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.set(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.isListening || model.finishing else { return .terminateNow }
        Task { @MainActor in
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appSettings) {
            Button("Set Up a Local Model (Free, Offline)…") {
                model.settingsTab = .listen
                openSettings()
            }
        }
        CommandMenu("Listening") {
            Button(model.isListening ? LocalizedStringKey("Stop Listening") : LocalizedStringKey("Start Listening")) { model.toggle() }
                .keyboardShortcut("l")
            Button("Clear Captions") { model.clear() }
                .keyboardShortcut("k")
            Button("New Segment…") { model.askNewSegment() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isListening)
            Button("New Segment Now") { model.quickNewSegment() }
                .globalShortcut(.newSegment)
                .disabled(!model.isListening)
            Divider()
            Toggle("Keep Window on Top", isOn: Bindable(model).settings.alwaysOnTop)
            Toggle("Translation Only", isOn: Bindable(model).settings.translationOnly)
            Toggle("Click Through Captions", isOn: Bindable(WindowControl.shared).clickThrough)
                .globalShortcut(.clickThrough)
        }
        CommandMenu("Speaker") {
            ForEach(Array(model.settings.speakerNames.indices.prefix(9)), id: \.self) { i in
                Button(model.speakerName(i) ?? "") { model.setCurrentSpeaker(i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .option)
            }
            Button("No Speaker") { model.setCurrentSpeaker(nil) }
                .keyboardShortcut("0", modifiers: .option)
            Divider()
            Button("Add Speaker…") { model.askAddSpeaker() }
        }
        CommandGroup(before: .windowList) {
            Button("Captions") { openWindow(id: "captions") }
                .keyboardShortcut("0")
            Button("Reply") { openWindow(id: "reply") }
                .keyboardShortcut("1")
            Button("Type a Reply") { WindowControl.shared.showReply() }
                .globalShortcut(.reply)
            Button("Script") { openWindow(id: "script") }
                .keyboardShortcut("2")
            Button("Summary") { openWindow(id: "summary") }
                .keyboardShortcut("3")
            Divider()
        }
    }
}
