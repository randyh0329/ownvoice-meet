// OwnVoice Meet for the Mac: a caption window that floats over the meeting, and Settings.
// Every word of the interface comes from Localizable.strings (en, zh-Hant, zh-Hans).

import SwiftUI

@main
struct OwnVoiceMeetApp: App {
    @State private var model = AppModel()

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
                Toggle("Keep Window on Top", isOn: $model.settings.alwaysOnTop)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
