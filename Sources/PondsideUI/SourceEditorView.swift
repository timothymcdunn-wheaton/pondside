import AppKit
import PondsideCore

/// The LilyPond source pane: a TextKit 2 `NSTextView`, configured as a code
/// editor (no smart quotes, no autocorrect), dark, with a legible mono font.
///
/// Tree-sitter highlighting and LSP-style services arrive in M5; this view
/// keeps to what M1 needs: editing, external-change merging that preserves
/// the caret, selection linking, and inline diagnostics.
@MainActor
final class SourceEditorView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView(usingTextLayoutManager: true)

    /// Called after every user edit with the full new text.
    var onUserEdit: ((String) -> Void)?
    /// Called when the selection changes (UTF-16 range).
    var onSelectionChange: ((NSRange) -> Void)?

    private var applyingProgrammaticChange = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tv = textView
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 14, height: 14)

        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false

        tv.font = Theme.monoFont
        tv.textColor = Theme.text
        tv.backgroundColor = Theme.editorBackground
        tv.drawsBackground = true
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.28)]
        tv.typingAttributes = baseAttributes
        tv.delegate = self

        scrollView.documentView = tv
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.monoFont, .foregroundColor: Theme.text]
    }

    var text: String { textView.string }

    /// Replaces the whole text (initial load). Clears undo.
    func load(_ string: String) {
        applyingProgrammaticChange = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: baseAttributes))
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        applyingProgrammaticChange = false
    }

    /// Merges an external edit as a single minimal replacement, so the caret,
    /// selection and scroll position of untouched text stay exactly where
    /// they were. The change is undoable like any other edit.
    func mergeExternal(_ newText: String) {
        guard let r = TextDiff.minimalReplacement(from: textView.string, to: newText) else { return }
        let range = NSRange(location: r.location, length: r.length)
        let oldSelections = textView.selectedRanges.map(\.rangeValue)
        let visibleOrigin = scrollView.contentView.bounds.origin

        applyingProgrammaticChange = true
        if textView.shouldChangeText(in: range, replacementString: r.replacement) {
            textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: r.replacement, attributes: baseAttributes))
            textView.didChangeText()
        }
        let mapped = oldSelections.map { sel -> NSValue in
            let start = r.mapOffset(sel.location)
            let end = r.mapOffset(sel.location + sel.length)
            return NSValue(range: NSRange(location: start, length: max(0, end - start)))
        }
        textView.selectedRanges = mapped
        applyingProgrammaticChange = false
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func select(_ range: NSRange, scroll: Bool = true) {
        let length = (textView.string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        textView.setSelectedRange(clamped)
        if scroll { textView.scrollRangeToVisible(clamped) }
    }

    /// Underlines diagnostic ranges using TextKit 2 rendering attributes, which
    /// decorate the text without editing it (and without touching undo).
    func showDiagnostics(_ ranges: [(NSRange, NSColor)]) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let doc = tlm.documentRange
        tlm.removeRenderingAttribute(.underlineStyle, for: doc)
        tlm.removeRenderingAttribute(.underlineColor, for: doc)
        for (r, color) in ranges {
            guard let start = tcm.location(doc.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: max(1, r.length)),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            tlm.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, for: textRange)
            tlm.addRenderingAttribute(.underlineColor, value: color, for: textRange)
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !applyingProgrammaticChange else { return }
        onUserEdit?(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProgrammaticChange else { return }
        onSelectionChange?(textView.selectedRange())
    }
}
