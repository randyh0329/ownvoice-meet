// Caption colors: what was said and its Chinese in different colors, on the theme's background.
// Terminal-style themes use a monospaced font; Custom takes the user's own colors.

import AppKit
import SwiftUI

enum CaptionTheme: String, CaseIterable, Codable, Identifiable {
    case system
    case terminalGreen = "terminal-green"
    case terminalAmber = "terminal-amber"
    case solarized
    case subtitles
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .terminalGreen: String(localized: "Terminal (green)")
        case .terminalAmber: String(localized: "Terminal (amber)")
        case .solarized: String(localized: "Solarized")
        case .subtitles: String(localized: "Subtitles")
        case .custom: String(localized: "Custom")
        }
    }
}

/// The colors and font a caption is drawn with.
struct CaptionStyle {
    /// nil: the window's own background.
    let background: Color?
    let heard: Color
    let translation: Color
    let monospaced: Bool

    /// A line still being spoken: the same color, dimmer.
    var partial: Color { heard.opacity(0.55) }

    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }

    static func of(_ s: AppSettings) -> CaptionStyle {
        switch s.captionTheme {
        case .system:
            CaptionStyle(background: nil, heard: .secondary, translation: .primary, monospaced: false)
        case .terminalGreen:
            CaptionStyle(background: Color(hex: "#0C0C0C"), heard: Color(hex: "#33FF66"), translation: Color(hex: "#FFE066"), monospaced: true)
        case .terminalAmber:
            CaptionStyle(background: Color(hex: "#0C0C0C"), heard: Color(hex: "#FFB000"), translation: Color(hex: "#F2F2F2"), monospaced: true)
        case .solarized:
            CaptionStyle(background: Color(hex: "#002B36"), heard: Color(hex: "#93A1A1"), translation: Color(hex: "#B58900"), monospaced: true)
        case .subtitles:
            CaptionStyle(background: Color(hex: "#000000"), heard: Color(hex: "#C8C8C8"), translation: Color(hex: "#FFE14D"), monospaced: false)
        case .custom:
            CaptionStyle(background: Color(hex: s.customBackground), heard: Color(hex: s.customHeard), translation: Color(hex: s.customTranslation), monospaced: s.customMonospaced)
        }
    }
}

extension Color {
    /// "#RRGGBB" in sRGB; anything else is gray.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self = Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB.
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        let byte = { (x: CGFloat) in Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
