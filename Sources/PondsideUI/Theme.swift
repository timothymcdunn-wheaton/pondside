import AppKit

/// The visual budget, in one place so it cannot drift (docs/DESIGN.md,
/// "Visual direction"): near-black chrome, one accent, hairline separators,
/// no text below the legibility floor, and the score never recoloured.
@MainActor
enum Theme {
    static let background = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.082, alpha: 1)
    static let chrome = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    static let editorBackground = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.100, alpha: 1)
    static let separator = NSColor(white: 1, alpha: 0.08)
    static let text = NSColor(white: 0.87, alpha: 1)
    static let secondaryText = NSColor(white: 0.58, alpha: 1)
    static let accent = NSColor(srgbRed: 0.40, green: 0.76, blue: 0.71, alpha: 1)
    static let warning = NSColor(srgbRed: 0.92, green: 0.74, blue: 0.38, alpha: 1)
    static let error = NSColor(srgbRed: 0.93, green: 0.43, blue: 0.41, alpha: 1)

    /// Paper is white, exactly as it prints. "Lights out" is a display filter
    /// drawn over the page, never a change to the music's colours.
    static let paper = NSColor.white
    static let lightsOutDim: CGFloat = 0.14

    /// Legibility floors: 13pt body, 11pt absolute minimum.
    static let bodySize: CGFloat = max(13, NSFont.preferredFont(forTextStyle: .body).pointSize)
    static let secondarySize: CGFloat = max(11, bodySize - 1)

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static var secondaryFont: NSFont { .systemFont(ofSize: secondarySize) }
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: bodySize, weight: .regular) }
}
