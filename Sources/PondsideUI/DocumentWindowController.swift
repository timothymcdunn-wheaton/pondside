import AppKit
import UniformTypeIdentifiers
import PondsideCore
import PondsideEngrave

/// One window: source and score side by side, a one-line status bar, and
/// bidirectional point-and-click between them.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let document: ScoreDocument
    private let editor = SourceEditorView(frame: .zero)
    private let canvas = ScoreCanvasView(frame: .zero)
    private let canvasScroll = NSScrollView()
    private let split = NSSplitView()
    private let statusBar = StatusBarView(frame: .zero)

    /// Positions currently selected in the score, in source order.
    private var selection: [SourcePosition] = []
    /// Set while the score drives the editor, so the editor's selection
    /// callback does not scroll the score the user is looking at.
    private var scoreIsDriving = false
    private var pendingConflict: String?

    var lightsOut: Bool {
        get { canvas.lightsOut }
        set { canvas.lightsOut = newValue }
    }

    init(document: ScoreDocument) {
        self.document = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.title = document.url.lastPathComponent
        window.representedURL = document.url
        window.minSize = NSSize(width: 640, height: 400)
        _ = window.setFrameAutosaveName("Pondside.\(document.url.path)")
        super.init(window: window)
        window.delegate = self
        buildLayout()
        wire()
        editor.load(document.text)
        document.delegate = self
        document.open()
        updateStatus()
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        canvasScroll.documentView = canvas
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.drawsBackground = true
        canvasScroll.backgroundColor = Theme.background
        canvasScroll.allowsMagnification = false
        canvasScroll.contentView.postsBoundsChangedNotifications = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(editor)
        split.addArrangedSubview(canvasScroll)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        content.addSubview(statusBar)

        // Content starts below the transparent title bar, so neither code
        // nor music ever sits under the traffic lights.
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            canvasScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        content.layoutSubtreeIfNeeded()
        split.setPosition((content.bounds.width * 0.4).rounded(), ofDividerAt: 0)
    }

    private func wire() {
        canvas.delegate = self
        canvas.onZoomChange = { [weak self] _ in self?.updateStatus() }
        editor.onUserEdit = { [weak self] text in
            self?.document.userEdited(text)
        }
        editor.onSelectionChange = { [weak self] range in
            self?.editorSelectionChanged(range)
        }
    }

    // MARK: Score → source

    private func select(positions: [SourcePosition], inEditor: Bool) {
        selection = positions.sorted()
        canvas.highlight(Set(selection), path: document.url.path, scrollToVisible: !scoreIsDriving)
        guard inEditor, let first = selection.first, let last = selection.last else { return }
        let source = SourceText(editor.text)
        guard let start = source.index(of: first), let lastStart = source.index(of: last) else { return }
        let end = LilyLexing.tokenRange(in: source.string, at: lastStart).upperBound
        let range = NSRange(location: source.utf16Offset(of: start),
                            length: source.utf16Offset(of: end) - source.utf16Offset(of: start))
        scoreIsDriving = true
        editor.select(range)
        scoreIsDriving = false
    }

    // MARK: Source → score

    private func editorSelectionChanged(_ range: NSRange) {
        guard !scoreIsDriving else { return }
        let source = SourceText(editor.text)
        let start = source.position(of: source.index(utf16Offset: range.location))
        if range.length == 0 {
            // The caret is "on" the linked token whose extent covers it.
            let candidates = document.linkedPositions.filter { $0.line == start.line && $0.character <= start.character }
            if let p = candidates.last, let i = source.index(of: p),
               source.string.unicodeScalars.distance(from: i, to: LilyLexing.tokenRange(in: source.string, at: i).upperBound) + p.character >= start.character {
                selection = [p]
            } else {
                selection = []
            }
        } else {
            let end = source.position(of: source.index(utf16Offset: range.location + range.length))
            selection = document.linkedPositions.filter { $0 >= start && $0 < end }
        }
        canvas.highlight(Set(selection), path: document.url.path, scrollToVisible: true)
        updateHints()
    }

    // MARK: Status

    private func updateStatus() {
        let lily = document.installation.map { "LilyPond \($0.version)" } ?? "LilyPond —"
        var note: String?
        if let declared = document.declaredVersion, let v = document.installation?.version, declared != v {
            note = "Score declares \(declared); compiling with \(v)"
        }
        statusBar.set(status: document.status, detail: firstErrorText(), zoom: canvas.zoom, toolchain: lily, note: note)
        updateHints()
    }

    private func firstErrorText() -> String? {
        guard let d = document.diagnostics.first(where: { $0.severity == .error || $0.severity == .fatal }) else { return nil }
        if let line = d.line { return "line \(line): \(d.message)" }
        return d.message
    }

    private func updateHints() {
        var hints: [String]
        if selection.isEmpty {
            hints = ["Click a note to find its source", "⌘J switch pane", "⌘E export PDF"]
        } else {
            hints = ["←/→ previous/next object", "⌘J edit in source", "Esc clear selection"]
        }
        if case .errors = document.status { hints.insert("Errors are underlined in the source", at: 0) }
        statusBar.setHints(Array(hints.prefix(3)))
    }

    private func showDiagnostics() {
        let source = SourceText(editor.text)
        let ranges: [(NSRange, NSColor)] = document.diagnostics.compactMap { d in
            guard let p = d.position(in: source), let i = source.index(of: p) else { return nil }
            let end = LilyLexing.tokenRange(in: source.string, at: i).upperBound
            let loc = source.utf16Offset(of: i)
            let color = d.severity == .warning ? Theme.warning : Theme.error
            return (NSRange(location: loc, length: max(1, source.utf16Offset(of: end) - loc)), color)
        }
        editor.showDiagnostics(ranges)
    }

    // MARK: Actions (reached via the responder chain from menus)

    @objc func zoomIn(_ sender: Any?) { canvas.setZoom(canvas.zoom * 1.2) }
    @objc func zoomOut(_ sender: Any?) { canvas.setZoom(canvas.zoom / 1.2) }
    @objc func zoomToFitWidth(_ sender: Any?) { canvas.fitWidth() }
    @objc func actualSize(_ sender: Any?) { canvas.setZoom(1) }

    @objc func switchPane(_ sender: Any?) {
        guard let window else { return }
        if window.firstResponder === editor.textView {
            window.makeFirstResponder(canvas)
        } else {
            window.makeFirstResponder(editor.textView)
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { @MainActor in await self.runExport(to: dest) }
        }
    }

    private func runExport(to dest: URL) async {
        statusBar.flash("Exporting PDF…")
        do {
            try await document.exportPDF(to: dest)
            statusBar.flash("Exported \(dest.lastPathComponent) — no local paths embedded")
        } catch {
            let alert = NSAlert(error: error)
            if let window { _ = await alert.beginSheetModal(for: window) }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        document.close()
        (NSApp.delegate as? PondsideAppDelegate)?.windowDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        document.revalidate()
    }
}

extension DocumentWindowController: ScoreCanvasDelegate {
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool) {
        guard let link else {
            select(positions: [], inEditor: false)
            updateHints()
            return
        }
        guard PathMatching.same(link.path, document.url.path) else {
            statusBar.flash("That object comes from \((link.path as NSString).lastPathComponent):\(link.line)")
            return
        }
        scoreIsDriving = true
        if extending, !selection.isEmpty {
            select(positions: selection + [link.position], inEditor: true)
        } else {
            select(positions: [link.position], inEditor: true)
        }
        scoreIsDriving = false
        updateHints()
    }

    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation]) {
        let mine = links.filter { PathMatching.same($0.path, document.url.path) }.map(\.position)
        guard let lo = mine.min(), let hi = mine.max() else { return }
        scoreIsDriving = true
        // A rectangle selects the contiguous source span it covers.
        select(positions: document.linkedPositions.filter { $0 >= lo && $0 <= hi }, inEditor: true)
        scoreIsDriving = false
        updateHints()
    }

    func canvas(_ canvas: ScoreCanvasView, moveSelectionBy step: Int) {
        let all = document.linkedPositions
        guard !all.isEmpty else { return }
        let next: SourcePosition
        if step > 0 {
            let anchor = selection.last
            next = anchor.flatMap { a in all.first { $0 > a } } ?? (anchor == nil ? all[0] : all[all.count - 1])
        } else {
            let anchor = selection.first
            next = anchor.flatMap { a in all.last { $0 < a } } ?? all[0]
        }
        select(positions: [next], inEditor: true)
        updateHints()
    }
}

extension DocumentWindowController: ScoreDocumentDelegate {
    func documentDidReloadFromDisk(_ document: ScoreDocument, text: String) {
        editor.mergeExternal(text)
        statusBar.flash("Reloaded — the file changed on disk")
    }

    func documentHasConflict(_ document: ScoreDocument, diskText: String) {
        guard let window, pendingConflict == nil else {
            pendingConflict = diskText
            return
        }
        pendingConflict = diskText
        let alert = NSAlert()
        alert.messageText = "\(document.url.lastPathComponent) changed on disk while you were typing"
        alert.informativeText = "Another program edited the file. Whichever version you don't keep is saved to ~/Library/Application Support/Pondside/Recovery, so nothing is lost."
        alert.addButton(withTitle: "Use the File on Disk")
        alert.addButton(withTitle: "Keep My Edits")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let disk = self.pendingConflict else { return }
            self.pendingConflict = nil
            self.document.resolveConflict(keepMine: response == .alertSecondButtonReturn, diskText: disk)
        }
    }

    func documentStatusDidChange(_ document: ScoreDocument) {
        updateStatus()
    }

    func documentDidEngrave(_ document: ScoreDocument) {
        let first = canvas.pages.isEmpty
        canvas.setPages(document.pages)
        if first { canvas.fitWidth() }
        canvas.highlight(Set(selection), path: document.url.path, scrollToVisible: false)
        showDiagnostics()
        updateStatus()
    }
}
