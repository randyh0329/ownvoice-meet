// Text size and background opacity for a reading window (captions, reply, script, summary), as in
// the first version: A− and A+ step through a few sizes, and only the background fades, never
// below 40%, because a fully clear window over a busy meeting cannot be read.

import Foundation

public enum WindowLook {
    /// The sizes A− and A+ step through, in points.
    public static let textSizes: [Double] = [12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36, 40, 44, 48]
    public static var textRange: ClosedRange<Double> { textSizes[0]...textSizes[textSizes.count - 1] }
    /// How opaque a window's background can be: 40% to fully solid.
    public static let opacityRange: ClosedRange<Double> = 0.4...1

    /// The next size up or down; a size between steps (from the Settings slider) moves to the
    /// nearest step that way, and the ends stay where they are.
    public static func stepText(_ size: Double, up: Bool) -> Double {
        if up { return textSizes.first { $0 > size } ?? textSizes[textSizes.count - 1] }
        return textSizes.last { $0 < size } ?? textSizes[0]
    }

    /// A stored opacity brought back into the range (an old or hand-edited setting).
    public static func clampOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }
}
