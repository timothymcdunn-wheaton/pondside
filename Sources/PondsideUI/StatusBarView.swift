import AppKit

/// The single always-on line of help and state at the bottom of the window:
/// compile indicator, the 2–3 most relevant actions, zoom and toolchain.
@MainActor
final class StatusBarView: NSView {
    private let dot = NSView()
    private let statusLabel = StatusBarView.label(Theme.secondaryText)
    private let hintsLabel = StatusBarView.label(Theme.secondaryText.withAlphaComponent(0.8))
    private let rightLabel = StatusBarView.label(Theme.secondaryText)
    private var flashTask: Task<Void, Never>?
    private var baseStatus = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.toolTip = "Engraving status — clean, compiling, or errors. Truth comes from LilyPond itself, never a guess."

        hintsLabel.lineBreakMode = .byTruncatingTail
        hintsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for v in [separator, dot, statusLabel, hintsLabel, rightLabel] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),

            hintsLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 24),
            hintsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintsLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightLabel.leadingAnchor, constant: -16),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.secondaryFont
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    func set(status: CompileStatus, detail: String?, zoom: CGFloat, toolchain: String, note: String?) {
        let color: NSColor
        switch status {
        case .idle: baseStatus = "Ready"; color = Theme.secondaryText
        case .noLilyPond: baseStatus = "LilyPond not found — install it (brew install lilypond)"; color = Theme.warning
        case .compiling: baseStatus = "Engraving…"; color = Theme.accent
        case .clean(let ms): baseStatus = "Clean · \(ms) ms"; color = Theme.accent.withAlphaComponent(0.55)
        case .errors(let n): baseStatus = "\(n) error\(n == 1 ? "" : "s")" + (detail.map { " — \($0)" } ?? ""); color = Theme.error
        case .failed(let why): baseStatus = why; color = Theme.error
        }
        dot.layer?.backgroundColor = color.cgColor
        if flashTask == nil { statusLabel.stringValue = baseStatus }
        statusLabel.toolTip = detail
        var right = "\(Int((zoom * 100).rounded()))%   \(toolchain)"
        if let note { right = note + "   " + right }
        rightLabel.stringValue = right
        rightLabel.toolTip = "Zoom: ⌘= / ⌘- / ⌘0 fit width. Toolchain: the LilyPond this score compiles with."
    }

    func setHints(_ hints: [String]) {
        hintsLabel.stringValue = hints.joined(separator: "   ·   ")
    }

    /// Shows a transient message in place of the status for a few seconds.
    func flash(_ message: String) {
        flashTask?.cancel()
        statusLabel.stringValue = message
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.flashTask = nil
            self.statusLabel.stringValue = self.baseStatus
        }
    }
}
