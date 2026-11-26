// Window behaviour SwiftUI does not offer on its own: the Reply, Script and Summary windows kept
// out of screen sharing, a captions window that lets clicks through to the meeting underneath,
// backgrounds that fade while the text stays solid, shortcuts that work while another app (Zoom)
// is in front, the menu bar item that turns click-through off again (a window that ignores the
// mouse cannot be clicked back), and keeping the Mac awake while listening.

import AppKit
import Carbon.HIToolbox
import OwnVoiceCore
import SwiftUI

// MARK: - Window control

@MainActor
@Observable
final class WindowControl {
    static let shared = WindowControl()

    /// The captions window ignores the mouse, so the meeting underneath can be clicked. Not kept
    /// between launches: the app should never open with a window that cannot be clicked.
    var clickThrough = false
    /// Shortcuts another app already holds: they then work only while OwnVoice Meet is in front.
    fileprivate(set) var takenShortcuts: [String] = []

    /// Taken from any window's environment, so a shortcut can open a window that is not open yet.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var windows: [String: WeakWindow] = [:]

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    fileprivate func register(_ window: NSWindow, as id: String) {
        windows[id] = WeakWindow(window: window)
    }

    func window(_ id: String) -> NSWindow? { windows[id]?.window }

    /// Opens (or brings back) a window, in front of whatever app is in front now.
    func show(_ id: String) {
        NSApp.activate()
        if let openWindow { openWindow(id: id) } else { window(id)?.makeKeyAndOrderFront(nil) }
    }

    /// The Reply window in front with its text field ready for typing (⌃⇧Space, from any app).
    func showReply() {
        show("reply")
        // The window may only now be opening: the field is looked for once it is there.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard let window = self.window("reply") else { return }
            window.makeKeyAndOrderFront(nil)
            if let field = Self.firstEditableText(in: window.contentView) { window.makeFirstResponder(field) }
        }
    }

    private static func firstEditableText(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let found = firstEditableText(in: sub) { return found }
        }
        return nil
    }
}

/// What a window asks of AppKit: its id (so a shortcut can find it), staying out of screen sharing,
/// letting clicks through, and no background of its own (the view draws a faded one instead).
struct WindowTraits: NSViewRepresentable {
    let id: String
    var hiddenFromCapture = false
    var ignoresMouse = false

    func makeNSView(context: Context) -> TraitsView { TraitsView() }

    func updateNSView(_ view: TraitsView, context: Context) {
        WindowControl.shared.openWindow = context.environment.openWindow
        view.traits = self
    }
}

final class TraitsView: NSView {
    var traits: WindowTraits? {
        didSet { DispatchQueue.main.async { [weak self] in self?.apply() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard let traits, let window else { return }
        WindowControl.shared.register(window, as: traits.id)
        window.sharingType = traits.hiddenFromCapture ? .none : .readOnly
        window.ignoresMouseEvents = traits.ignoresMouse
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

extension View {
    /// Applies `WindowTraits`; the window's own background is left out (see `fadedBackground`).
    func windowTraits(_ id: String, hiddenFromCapture: Bool = false, ignoresMouse: Bool = false) -> some View {
        containerBackground(Color.clear, for: .window)
            .background(WindowTraits(id: id, hiddenFromCapture: hiddenFromCapture, ignoresMouse: ignoresMouse))
    }

    /// A background that fades to `opacity` (the text in front stays solid), under the title bar too.
    func fadedBackground(_ opacity: Double, _ color: Color = Color(nsColor: .windowBackgroundColor)) -> some View {
        background(color.opacity(opacity).ignoresSafeArea())
    }
}

/// A− / A+ and the background slider, for a window's bar.
struct LookControls: View {
    let size: Binding<Double>
    let opacity: Binding<Double>

    var body: some View {
        HStack(spacing: 2) {
            Button {
                size.wrappedValue = WindowLook.stepText(size.wrappedValue, up: false)
            } label: {
                Text(verbatim: "A−")
            }
            .disabled(size.wrappedValue <= WindowLook.textRange.lowerBound)
            .help("Smaller text")
            Button {
                size.wrappedValue = WindowLook.stepText(size.wrappedValue, up: true)
            } label: {
                Text(verbatim: "A+")
            }
            .disabled(size.wrappedValue >= WindowLook.textRange.upperBound)
            .help("Larger text")
            Slider(value: opacity, in: WindowLook.opacityRange)
                .frame(width: 64)
                .padding(.leading, 6)
                .accessibilityLabel(Text("Background opacity"))
                .help("Background opacity: slide left to see what is behind the window. The text stays solid.")
        }
        .controlSize(.small)
        .fixedSize()
    }
}

// MARK: - Menu bar

/// The menu bar item: the way back from click-through, and listening without the captions window.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isListening ? LocalizedStringKey("Stop Listening") : LocalizedStringKey("Start Listening")) { model.toggle() }
        Toggle("Click Through Captions", isOn: Bindable(WindowControl.shared).clickThrough)
            .globalShortcut(.clickThrough)
        Toggle("Keep Window on Top", isOn: Bindable(model).settings.alwaysOnTop)
        Toggle("Translation Only", isOn: Bindable(model).settings.translationOnly)
        Divider()
        Button("Show Captions") { WindowControl.shared.show("captions") }
        Button("Type a Reply") { WindowControl.shared.showReply() }
            .globalShortcut(.reply)
        Button("New Segment Now") { model.quickNewSegment() }
            .globalShortcut(.newSegment)
            .disabled(!model.isListening)
        Divider()
        Button("Quit OwnVoice Meet") { NSApp.terminate(nil) }
    }
}

// MARK: - Shortcuts from any app

/// Shortcuts that work whichever app is in front: Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission. All use ⌃⇧.
enum GlobalShortcut: UInt32, CaseIterable {
    case reply = 1, newSegment, clickThrough

    /// The key, as Carbon numbers it.
    fileprivate var keyCode: UInt32 {
        switch self {
        case .reply: UInt32(kVK_Space)
        case .newSegment: UInt32(kVK_F9)
        case .clickThrough: UInt32(kVK_F8)
        }
    }

    /// The same key for a menu item, so the menus show it.
    var key: KeyEquivalent {
        switch self {
        case .reply: .space
        case .newSegment: KeyEquivalent(Character(UnicodeScalar(UInt32(NSF9FunctionKey))!))
        case .clickThrough: KeyEquivalent(Character(UnicodeScalar(UInt32(NSF8FunctionKey))!))
        }
    }

    static let modifiers: EventModifiers = [.control, .shift]

    var symbol: String {
        switch self {
        case .reply: "⌃⇧Space"
        case .newSegment: "⌃⇧F9"
        case .clickThrough: "⌃⇧F8"
        }
    }

    @MainActor
    func perform() {
        switch self {
        case .reply: WindowControl.shared.showReply()
        case .newSegment: if !AppModel.shared.quickNewSegment() { NSSound.beep() }
        case .clickThrough: WindowControl.shared.clickThrough.toggle()
        }
    }
}

extension View {
    /// Shows a global shortcut on a menu item (pressing it reaches the shortcut first).
    func globalShortcut(_ shortcut: GlobalShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: GlobalShortcut.modifiers)
    }
}

/// "OVMT": marks this app's hot keys.
private let hotKeySignature: OSType = 0x4F56_4D54

@MainActor
enum GlobalHotKeys {
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    /// Called once at launch.
    static func registerAll() {
        guard !installed else { return }
        installed = true
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyPressed, 1, &pressed, nil, nil)
        var taken: [String] = []
        for shortcut in GlobalShortcut.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: shortcut.rawValue)
            let status = RegisterEventHotKey(shortcut.keyCode, UInt32(controlKey | shiftKey), id, GetEventDispatcherTarget(), 0, &ref)
            if status == OSStatus(noErr), let ref { refs.append(ref) } else { taken.append(shortcut.symbol) }
        }
        WindowControl.shared.takenShortcuts = taken
    }
}

/// Carbon calls this on the main thread for each of the shortcuts, whichever app is in front.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == OSStatus(noErr), id.signature == hotKeySignature, let shortcut = GlobalShortcut(rawValue: id.id) else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in shortcut.perform() }
    return OSStatus(noErr)
}

// MARK: - Keeping the Mac awake

/// While listening, neither the Mac nor its display goes to sleep on its own (a long talk with
/// nobody touching the keyboard). Ended when the session ends, on an error, and at quit.
@MainActor
enum KeepAwake {
    private static var activity: NSObjectProtocol?

    static func set(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "OwnVoice Meet is listening to a meeting"
            )
        } else if !on, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
