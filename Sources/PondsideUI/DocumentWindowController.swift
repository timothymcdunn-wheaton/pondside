import AppKit
import UniformTypeIdentifiers
import PondsideCore
import PondsideEngrave

/// One window: source and score side by side, a one-line status bar, and
/// bidirectional point-and-click between them. The score is an editor too:
/// keyboard note input turns into minimal text edits on the same undo stack.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let score: ScoreDocument
    private let editor = SourceEditorView(frame: .zero)
    private let canvas = ScoreCanvasView(frame: .zero)
    private let canvasScroll = NSScrollView()
    private let split = NSSplitView()
    private let statusBar = StatusBarView(frame: .zero)

    private var noteInput = NoteInput()
    /// Set while the score drives the editor, so the editor's selection
    /// callback does not scroll the score the user is looking at.
    private var scoreIsDriving = false
    private var pendingConflict: String?

    var lightsOut: Bool {
        get { canvas.lightsOut }
        set { canvas.lightsOut = newValue }
    }

    init(document: ScoreDocument) {
        self.score = document
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
        editor.load(score.text)
        score.delegate = self
        score.open()
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
            guard let self else { return }
            self.score.userEdited(text)
            self.rebuildEngravingMap()
        }
        editor.onSelectionChange = { [weak self] range in
            self?.editorSelectionChanged(range)
        }
    }

    // MARK: Selection model
    //
    // The text selection is the single source of truth. Selecting in the
    // score selects the characters of the chosen events; score operations
    // act on whatever events the text selection covers. Highlights are
    // derived from it, through the engraving map while the canvas still
    // shows the previous engraving.

    private var tree: SyntaxTree { score.tree }

    /// The selection as UTF-8 offsets into the current text.
    private func selectionUTF8() -> Range<Int> {
        let r = editor.textView.selectedRange()
        let text = editor.text
        let a = OffsetConversion.utf8(fromUTF16: r.location, in: text)
        let b = OffsetConversion.utf8(fromUTF16: r.location + r.length, in: text)
        return a..<max(a, b)
    }

    /// What score operations act on: whole events, or a single chord
    /// member when the selection lies inside one.
    private func targets() -> (events: [Int], notes: [Int]) {
        let r = selectionUTF8()
        if !r.isEmpty, let n = tree.notes.firstIndex(where: { $0.role == .event && $0.spelledRange.lowerBound <= r.lowerBound && r.upperBound <= $0.spelledRange.upperBound }),
           let e = tree.notes[n].event, tree.events[e].kind == .chord {
            return ([], [n])
        }
        if r.isEmpty {
            if let e = tree.eventIndex(at: r.lowerBound), tree.events[e].range.upperBound > r.lowerBound || tree.events[e].range.isEmpty {
                return ([e], [])
            }
            return ([], [])
        }
        return (tree.eventIndices(overlapping: r), [])
    }

    private func setSelection(utf8 range: Range<Int>, scroll: Bool = true) {
        let text = editor.text
        let a = OffsetConversion.utf16(fromUTF8: range.lowerBound, in: text)
        let b = OffsetConversion.utf16(fromUTF8: range.upperBound, in: text)
        scoreIsDriving = true
        editor.select(NSRange(location: a, length: b - a), scroll: scroll)
        scoreIsDriving = false
        refreshHighlight(reveal: true)
    }

    private func selectEvents(_ indices: [Int]) {
        guard let first = indices.min(), let last = indices.max() else { return }
        setSelection(utf8: tree.events[first].range.lowerBound..<tree.events[last].range.upperBound)
    }

    private var engraving: EngravingMap?
    /// Linked positions of the current pages with their UTF-16 offsets in
    /// the engraved text, sorted by offset.
    private var linkOffsets: [(offset: Int, position: SourcePosition)] = []

    private func rebuildEngravingMap() {
        guard let engraved = score.engravedText else { engraving = nil; return }
        let map = EngravingMap(engraved: engraved, current: editor.text)
        engraving = map
        linkOffsets = score.linkedPositions
            .compactMap { p -> (offset: Int, position: SourcePosition)? in
                map.engravedOffset(of: p).map { (offset: $0, position: p) }
            }
            .sorted { $0.offset < $1.offset }
    }

    private func refreshHighlight(reveal: Bool) {
        guard let map = engraving else { return }
        let text = editor.text
        var r = selectionUTF8()
        if r.isEmpty {
            // A caret inside an event highlights that event.
            if let e = tree.eventIndex(at: r.lowerBound), tree.events[e].range.upperBound > r.lowerBound {
                r = tree.events[e].range
            }
        }
        var positions = Set<SourcePosition>()
        if !r.isEmpty {
            let a = map.engravedOffset(forCurrent: OffsetConversion.utf16(fromUTF8: r.lowerBound, in: text))
            let b = map.engravedOffset(forCurrent: OffsetConversion.utf16(fromUTF8: r.upperBound, in: text))
            for l in linkOffsets where l.offset >= a && l.offset < max(b, a + 1) { positions.insert(l.position) }
        }
        hasSelection = !positions.isEmpty
        canvas.highlight(positions, path: score.url.path, reveal: reveal)
        updateHints()
    }

    private var hasSelection = false

    /// The current-text UTF-8 offset of a point-and-click link.
    private func currentOffset(of link: PointAndClickLocation) -> Int? {
        guard let map = engraving, let engraved = map.engravedOffset(of: link.position) else { return nil }
        let current16 = map.currentOffset(forEngraved: engraved)
        return OffsetConversion.utf8(fromUTF16: current16, in: editor.text)
    }

    private func editorSelectionChanged(_ range: NSRange) {
        guard !scoreIsDriving else { return }
        refreshHighlight(reveal: true)
    }

    // MARK: Applying score edits

    /// Applies a score edit as one undoable change, then selects its result.
    private func apply(_ edit: ScoreEdit?) {
        guard let edit, !edit.isEmpty else { NSSound.beep(); return }
        let old = editor.text
        let oldBytes = Array(old.utf8)
        let newBytes = edit.edits.apply(to: oldBytes)
        // One replacement spanning the edits: the file result is identical,
        // and the text view gets a single undo step.
        let lo = edit.edits.map(\.range.lowerBound).min()!
        let hi = edit.edits.map(\.range.upperBound).max()!
        let newHi = hi + newBytes.count - oldBytes.count
        let replacement = String(decoding: newBytes[lo..<newHi], as: UTF8.self)
        let a = OffsetConversion.utf16(fromUTF8: lo, in: old)
        let b = OffsetConversion.utf16(fromUTF8: hi, in: old)
        editor.replace(NSRange(location: a, length: b - a), with: replacement, actionName: edit.name)

        // The document re-parsed synchronously; select what the edit produced.
        let new = tree
        let selected = edit.selectionAnchors.compactMap { anchor in
            new.events.firstIndex { $0.range.lowerBound == anchor } ?? new.eventIndex(at: anchor)
        }
        if selected.isEmpty {
            setSelection(utf8: lo..<lo, scroll: false)
        } else {
            selectEvents(selected)
        }
    }

    // MARK: Keyboard note input

    private func keyInput(for event: NSEvent) -> KeyInput? {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let command = flags.contains(.command), control = flags.contains(.control)
        func k(_ key: KeyInput.Key) -> KeyInput {
            KeyInput(key, shift: shift, option: option, command: command, control: control)
        }
        switch event.specialKey {
        case .upArrow?: return k(.up)
        case .downArrow?: return k(.down)
        case .leftArrow?: return k(.left)
        case .rightArrow?: return k(.right)
        case .delete?, .deleteForward?, .backspace?: return k(.delete)
        case .carriageReturn?, .enter?, .newline?: return k(.enter)
        default: break
        }
        if event.keyCode == 53 { return k(.escape) }
        // Use the typed character (layout-aware), keeping shift for symbols.
        guard let c = event.characters?.first else { return nil }
        return KeyInput(.character(c), shift: false, option: false, command: command, control: control)
    }

    private func handleScoreKey(_ event: NSEvent) -> Bool {
        guard let input = keyInput(for: event) else { return false }
        let actions = noteInput.handle(input, now: event.timestamp)
        if actions.isEmpty { return false }
        for action in actions { perform(action) }
        return true
    }

    private func perform(_ action: InputAction) {
        let scoreEditor = ScoreEditor(tree)
        let (events, notes) = targets()
        switch action {
        case .move(let move):
            apply(scoreEditor.move(events: events, extraNotes: notes, by: move))
        case .setDuration(let d):
            if !events.isEmpty { apply(scoreEditor.setDuration(events: events, to: d)) }
            updateInputStatus()
        case .toggleDot:
            if !events.isEmpty { apply(scoreEditor.toggleDot(events: events)) }
            updateInputStatus()
        case .insertNote(let step):
            insert(step: step)
        case .insertRest:
            insert(step: nil)
        case .delete:
            apply(scoreEditor.delete(events: events))
        case .togglePostEvent(let text):
            let eligible = events.filter { tree.events[$0].acceptsNoteEntry }
            apply(scoreEditor.togglePostEvent(text, events: eligible))
        case .select(let step, let extend):
            moveSelection(by: step, extend: extend)
        case .clearSelection:
            let r = selectionUTF8()
            let end = tree.eventIndex(at: r.upperBound).map { tree.events[$0].range.upperBound } ?? r.upperBound
            setSelection(utf8: end..<end, scroll: false)
        case .editSource:
            window?.makeFirstResponder(editor.textView)
        case .buffer:
            updateInputStatus()
        }
    }

    private func insert(step: Int?) {
        let r = selectionUTF8()
        // After the selected event, or after the event just before the caret.
        let anchor = targets().events.max()
            ?? tree.events.lastIndex { $0.range.upperBound <= r.lowerBound && $0.acceptsNoteEntry }
        guard let anchor, tree.events[anchor].acceptsNoteEntry else {
            statusBar.flash("Select a note to insert after (or type it in the source)")
            NSSound.beep()
            return
        }
        apply(ScoreEditor(tree).insert(step: step, after: anchor, duration: noteInput.armedDuration))
    }

    private func moveSelection(by step: Int, extend: Bool) {
        let all = tree.events.indices.filter { tree.events[$0].kind != .lyric }
        guard !all.isEmpty else { return }
        let current = targets().events
        let r = selectionUTF8()
        let events = tree.events
        let next: Int
        if step > 0 {
            if let c = current.max() {
                next = all.first { $0 > c } ?? all.last!
            } else {
                next = all.first { events[$0].range.lowerBound >= r.lowerBound } ?? all.last!
            }
        } else {
            if let c = current.min() {
                next = all.last { $0 < c } ?? all.first!
            } else {
                next = all.last { events[$0].range.upperBound <= r.lowerBound } ?? all.first!
            }
        }
        if extend, let lo = current.min(), let hi = current.max() {
            selectEvents([min(lo, next), max(hi, next)])
        } else {
            selectEvents([next])
        }
    }

    private func updateInputStatus() {
        statusBar.setInput(armed: noteInput.armedDuration?.text, buffer: noteInput.bufferText)
    }

    // MARK: Status

    private func updateStatus() {
        let lily = score.installation.map { "LilyPond \($0.version)" } ?? "LilyPond —"
        var note: String?
        if let declared = score.declaredVersion, let v = score.installation?.version, declared != v {
            note = "Score declares \(declared); compiling with \(v)"
        }
        statusBar.set(status: score.status, detail: firstErrorText(), zoom: canvas.zoom, toolchain: lily, note: note)
        updateHints()
    }

    private func firstErrorText() -> String? {
        guard let d = score.diagnostics.first(where: { $0.severity == .error || $0.severity == .fatal }) else { return nil }
        if let line = d.line { return "line \(line): \(d.message)" }
        return d.message
    }

    private func updateHints() {
        var hints: [String]
        if hasSelection {
            hints = ["↑↓ pitch  ⇧ octave  ⌥ accidental", "1 2 4 8 16 duration  . dot", "a–g insert  ⌫ delete"]
        } else {
            hints = ["Click a note to select it", "←→ walk the score", "⌘J switch pane"]
        }
        if case .errors = score.status { hints.insert("Errors are underlined in the source", at: 0) }
        statusBar.setHints(Array(hints.prefix(3)))
    }

    private func showDiagnostics() {
        let text = editor.text
        let source = SourceText(score.compiledText ?? text)
        let map = EngravingMap(engraved: score.compiledText ?? text, current: text)
        let current = SourceText(text)
        let ranges: [(NSRange, NSColor)] = score.diagnostics.compactMap { d in
            guard let p = d.position(in: source), let i = source.index(of: p) else { return nil }
            let loc = map.currentOffset(forEngraved: source.utf16Offset(of: i))
            let start = current.index(utf16Offset: loc)
            let end = LilyLexing.tokenRange(in: current.string, at: start).upperBound
            let color = d.severity == .warning ? Theme.warning : Theme.error
            return (NSRange(location: loc, length: max(1, current.utf16Offset(of: end) - loc)), color)
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
        panel.nameFieldStringValue = score.url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = score.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { @MainActor in await self.runExport(to: dest) }
        }
    }

    private func runExport(to dest: URL) async {
        statusBar.flash("Exporting PDF…")
        do {
            try await score.exportPDF(to: dest)
            statusBar.flash("Exported \(dest.lastPathComponent) — no local paths embedded")
        } catch {
            let alert = NSAlert(error: error)
            if let window { _ = await alert.beginSheetModal(for: window) }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([score.url])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        score.close()
        (NSApp.delegate as? PondsideAppDelegate)?.windowDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        score.revalidate()
    }
}

extension DocumentWindowController: ScoreCanvasDelegate {
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool) {
        guard let link else {
            perform(.clearSelection)
            return
        }
        guard PathMatching.same(link.path, score.url.path) else {
            statusBar.flash("That object comes from \((link.path as NSString).lastPathComponent):\(link.line)")
            return
        }
        guard let offset = currentOffset(of: link) else { return }
        // A chord member selects just that note, so ↑↓ move it alone.
        var range: Range<Int>
        if let n = tree.noteIndex(startingAt: offset), let e = tree.notes[n].event, tree.events[e].kind == .chord {
            range = tree.notes[n].spelledRange
        } else if let e = tree.eventIndex(at: offset) {
            range = tree.events[e].range
        } else {
            return
        }
        if extending {
            let current = selectionUTF8()
            range = min(current.lowerBound, range.lowerBound)..<max(current.upperBound, range.upperBound)
        }
        setSelection(utf8: range)
    }

    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation]) {
        let offsets = links.filter { PathMatching.same($0.path, score.url.path) }.compactMap { currentOffset(of: $0) }
        let events = Set(offsets.compactMap { tree.eventIndex(at: $0) })
        guard !events.isEmpty else { return }
        // A rectangle selects the contiguous source span it covers.
        selectEvents(Array(events))
    }

    func canvas(_ canvas: ScoreCanvasView, handleKey event: NSEvent) -> Bool {
        handleScoreKey(event)
    }
}

extension DocumentWindowController: ScoreDocumentDelegate {
    func documentDidReloadFromDisk(_ document: ScoreDocument, text: String) {
        editor.mergeExternal(text)
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        statusBar.flash("Reloaded — the file changed on disk")
    }

    func documentHasConflict(_ document: ScoreDocument, diskText: String) {
        guard let window, pendingConflict == nil else {
            pendingConflict = diskText
            return
        }
        pendingConflict = diskText
        let alert = NSAlert()
        alert.messageText = "\(score.url.lastPathComponent) changed on disk while you were typing"
        alert.informativeText = "Another program edited the file. Whichever version you don't keep is saved to ~/Library/Application Support/Pondside/Recovery, so nothing is lost."
        alert.addButton(withTitle: "Use the File on Disk")
        alert.addButton(withTitle: "Keep My Edits")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let disk = self.pendingConflict else { return }
            self.pendingConflict = nil
            self.score.resolveConflict(keepMine: response == .alertSecondButtonReturn, diskText: disk)
        }
    }

    func documentStatusDidChange(_ document: ScoreDocument) {
        updateStatus()
    }

    func documentDidEngrave(_ document: ScoreDocument) {
        let first = canvas.pages.isEmpty
        canvas.setPages(score.pages)
        if first { canvas.fitWidth() }
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        showDiagnostics()
        updateStatus()
    }
}
