// OwnVoice Meet for the Mac: a caption window that floats over the meeting, and Settings.
// Every word of the interface comes from Localizable.strings (en, zh-Hant, zh-Hans).
// No @State anywhere: with the macOS 27 SDK it is a macro whose plugin ships only with Xcode, and
// the app also builds with the Command Line Tools. State lives in AppModel (Observation's macros
// are in both).

import SwiftUI

@main
struct OwnVoiceMeetApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        Window("OwnVoice Meet", id: "captions") {
            CaptionsView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 440)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Listening") {
                Button(model.isListening ? LocalizedStringKey("Stop Listening") : LocalizedStringKey("Start Listening")) { model.toggle() }
                    .keyboardShortcut("l")
                Button("Clear Captions") { model.clear() }
                    .keyboardShortcut("k")
                Divider()
                Toggle("Keep Window on Top", isOn: Bindable(model).settings.alwaysOnTop)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
