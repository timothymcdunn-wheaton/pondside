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
    /// The Notation Lens's paper, a shade off white so a preview floating
    /// over the dark chrome doesn't glow brighter than the page (HIG, Dark Mode).
    static let lensPaper = NSColor(white: 0.93, alpha: 1)

    /// Legibility floors: 13pt body, 11pt absolute minimum.
    static let bodySize: CGFloat = max(13, NSFont.preferredFont(forTextStyle: .body).pointSize)
    static let secondarySize: CGFloat = max(11, bodySize - 1)

    /// Secondary text on glass. The page behind can be white, so glass is
    /// dimmed (`GlassView`) and its secondary text is lighter than on solid
    /// chrome, to stay above 4.5:1 (HIG Accessibility).
    static let glassSecondaryText = NSColor(white: 0.78, alpha: 1)

    /// Source colours, from the CST's token kinds: quiet, with commands in
    /// the accent's family and everything ≥ 4.5:1 on the editor background.
    static let syntaxCommand = NSColor(srgbRed: 0.52, green: 0.80, blue: 0.76, alpha: 1)
    static let syntaxComment = NSColor(white: 0.55, alpha: 1)
    static let syntaxString = NSColor(srgbRed: 0.88, green: 0.75, blue: 0.56, alpha: 1)
    static let syntaxNumber = NSColor(srgbRed: 0.70, green: 0.78, blue: 0.96, alpha: 1)
    static let syntaxScheme = NSColor(srgbRed: 0.78, green: 0.70, blue: 0.94, alpha: 1)
    static let syntaxPunctuation = NSColor(white: 0.66, alpha: 1)

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static var secondaryFont: NSFont { .systemFont(ofSize: secondarySize) }
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: bodySize, weight: .regular) }
}

/// Floating chrome over the score: blurred, as before, but with a dark
/// layer inside so a white page behind doesn't wash the text out (HIG
/// Materials: dim clear glass over bright content). Reduce Transparency
/// makes it solid; Increase Contrast darkens it further and adds a border.
@MainActor
class GlassView: NSVisualEffectView {
    private let dim = NSView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        dim.wantsLayer = true
        dim.frame = bounds
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)   // first, so content draws above it
        applyAccessibility()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func displayOptionsChanged() { applyAccessibility() }

    private func applyAccessibility() {
        let ws = NSWorkspace.shared
        if ws.accessibilityDisplayShouldReduceTransparency {
            state = .inactive
            dim.layer?.backgroundColor = Theme.chrome.cgColor
        } else {
            state = .active
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(ws.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.5).cgColor
        }
        layer?.borderWidth = ws.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
    }
}
