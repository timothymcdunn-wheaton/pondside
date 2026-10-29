import AppKit

/// What the empty score pane shows while the first engraving runs: a
/// staff drawing itself line by line and a note settling on it, then
/// fading to start again. No text — the status bar already says
/// "Engraving..." — and no spinner, so it reads as part of the page
/// rather than as a wait (HIG Loading: show something as soon as
/// possible). It appears only once an engraving has run 250 ms, so a
/// quick one never flashes it, and under Reduce Motion it is a still
/// staff.
@MainActor
final class EngravingPlaceholderView: NSView {
    // Small, faint and slow: it fills an empty pane, it shouldn't call for attention.
    private static let width: CGFloat = 48
    private static let gap: CGFloat = 5
    private static let cycle: CFTimeInterval = 3.2

    private let lines: [CAShapeLayer] = (0..<5).map { _ in CAShapeLayer() }
    private let note = CAShapeLayer()
    private var showTask: Task<Void, Never>?
    private(set) var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Centred by frame, not constraints: its superview is a scroll view,
        // which lays out by frames, so constraints there go stale on resize.
        // Flexible margins keep it centred as the pane resizes.
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Engraving the score")

        for (i, line) in lines.enumerated() {
            let y = CGFloat(i) * Self.gap
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: Self.width, y: y))
            line.path = path
            line.strokeColor = Theme.secondaryText.withAlphaComponent(0.3).cgColor
            line.lineWidth = 1
            line.lineCap = .round
            layer?.addSublayer(line)
        }
        // A black notehead in the second space from the top, tilted as engraved.
        let head = CGRect(x: -3.2, y: -2.5, width: 6.4, height: 5)
        let path = CGMutablePath()
        path.addEllipse(in: head, transform: CGAffineTransform(rotationAngle: -0.35))
        note.path = path
        note.fillColor = Theme.accent.withAlphaComponent(0.5).cgColor
        note.position = CGPoint(x: Self.width * 0.62, y: Self.gap * 2.5)
        layer?.addSublayer(note)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.gap * 4) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the animation while `active`; hides it at once when not.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        showTask?.cancel()
        showTask = nil
        guard active else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard !self.isActive else { return }
                    self.isHidden = true
                    self.stopAnimating()
                }
            })
            return
        }
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.center()
            self.isHidden = false
            self.startAnimating()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    private func center() {
        guard let bounds = superview?.bounds else { return }
        let size = intrinsicContentSize
        frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
    }

    private func startAnimating() {
        stopAnimating()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        for (i, line) in lines.enumerated() {
            // Lines draw left to right, each a beat after the one above.
            let start = Double(i) * 0.04
            let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
            draw.values = [0, 0, 1, 1]
            draw.keyTimes = [0, start, start + 0.3, 1].map { NSNumber(value: $0) }
            draw.timingFunctions = [.init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
            line.add(loop([draw, fadeOut()], from: now), forKey: "pondside.engraving")
        }
        let appear = CAKeyframeAnimation(keyPath: "opacity")
        appear.values = [0, 0, 1, 1, 0, 0]
        appear.keyTimes = [0, 0.5, 0.58, 0.78, 0.92, 1].map { NSNumber(value: $0) }
        note.add(loop([appear], from: now), forKey: "pondside.engraving")
    }

    private func fadeOut() -> CAKeyframeAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0, 0]
        fade.keyTimes = [0, 0.78, 0.92, 1].map { NSNumber(value: $0) }
        return fade
    }

    private func loop(_ animations: [CAAnimation], from start: CFTimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = Self.cycle
        group.repeatCount = .infinity
        group.beginTime = start
        return group
    }

    private func stopAnimating() {
        for line in lines { line.removeAnimation(forKey: "pondside.engraving") }
        note.removeAnimation(forKey: "pondside.engraving")
    }
}
