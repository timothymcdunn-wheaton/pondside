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
    private let editorPane = NSView()
    private let compilerOutput = CompilerOutputView(frame: .zero)
    private var panes: PaneHost!
    private var help: HelpOverlay!
    private var chord = ChordRecognizer()
    private var keyMonitor: Any?
    private let statusBar = StatusBarView(frame: .zero)

    private var noteInput = NoteInput()
    /// Set while the score drives the editor, so the editor's selection
    /// callback does not scroll the score the user is looking at.
    private var scoreIsDriving = false
    private var pendingConflict: (file: SourceFile, disk: String)?
    /// The file shown in the source pane; score edits apply to it.
    private(set) var activeFile: SourceFile
    private let fileMenu = NSPopUpButton(frame: .zero, pullsDown: false)

    var lightsOut: Bool {
        get { canvas.lightsOut }
        set { canvas.lightsOut = newValue }
    }

    init(document: ScoreDocument) {
        self.score = document
        // Start where the music is: the root, unless it only includes parts.
        self.activeFile = document.root.hasNotes ? document.root : (document.files.first { $0.hasNotes } ?? document.root)
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
        installKeyMonitor()
        showFile(activeFile)
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

        // The source pane: a one-line file bar over the editor.
        let fileBar = NSView()
        fileBar.wantsLayer = true
        fileBar.layer?.backgroundColor = Theme.chrome.cgColor
        fileMenu.translatesAutoresizingMaskIntoConstraints = false
        fileMenu.isBordered = false
        fileMenu.font = Theme.secondaryFont
        fileMenu.target = self
        fileMenu.action = #selector(fileMenuChanged(_:))
        fileMenu.toolTip = "The file shown in the source pane — ⌘⇧] next, ⌘⇧[ previous. Clicking a note in the score opens its file."
        for v in [fileBar, editor] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            editorPane.addSubview(v)
        }
        fileBar.addSubview(fileMenu)
        NSLayoutConstraint.activate([
            fileBar.topAnchor.constraint(equalTo: editorPane.topAnchor),
            fileBar.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            fileBar.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            fileBar.heightAnchor.constraint(equalToConstant: 28),
            fileMenu.leadingAnchor.constraint(equalTo: fileBar.leadingAnchor, constant: 10),
            fileMenu.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            fileMenu.trailingAnchor.constraint(lessThanOrEqualTo: fileBar.trailingAnchor, constant: -10),
            editor.topAnchor.constraint(equalTo: fileBar.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
        ])

        // Panes are frames, content is cargo (DESIGN.md, M3).
        panes = PaneHost(layout: Self.savedLayout()) { [unowned self] content in self.makeContent(content) }
        let split = panes.split
        split.translatesAutoresizingMaskIntoConstraints = false
        help = HelpOverlay(window: window!)
        help.register(fileMenu, "go.file")
        help.register(statusBar, "help.context")

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
        ])
        content.layoutSubtreeIfNeeded()
        panes.applyFractions()
    }

    private func wire() {
        canvas.delegate = self
        canvas.onZoomChange = { [weak self] _ in self?.updateStatus() }
        editor.onUserEdit = { [weak self] text in
            guard let self else { return }
            self.score.userEdited(self.activeFile, text: text)
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

    private var tree: SyntaxTree { activeFile.tree }

    // MARK: Files

    /// Shows `file` in the source pane. Selection, highlight and score
    /// edits all follow the visible file.
    private func showFile(_ file: SourceFile) {
        activeFile = file
        editor.show(file.url, text: file.text, undoManager: file.undoManager)
        rebuildFileMenu()
        rebuildEngravingMap()
        showDiagnostics()
        refreshHighlight(reveal: false)
        updateStatus()
    }

    private func rebuildFileMenu() {
        fileMenu.removeAllItems()
        for (i, f) in score.files.enumerated() {
            var title = f.displayName
            if i == 0 { title += "  (root)" }
            if !f.hasNotes { title += "  — no notes" }
            fileMenu.addItem(withTitle: title)
            fileMenu.lastItem?.representedObject = f.url
        }
        if let i = score.files.firstIndex(where: { $0 === activeFile }) { fileMenu.selectItem(at: i) }
    }

    @objc private func fileMenuChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard score.files.indices.contains(i) else { return }
        showFile(score.files[i])
    }

    @objc func nextFile(_ sender: Any?) { stepFile(1) }
    @objc func previousFile(_ sender: Any?) { stepFile(-1) }

    private func stepFile(_ step: Int) {
        let files = score.files
        guard let i = files.firstIndex(where: { $0 === activeFile }), files.count > 1 else { return }
        showFile(files[(i + step + files.count) % files.count])
        statusBar.flash("Editing \(activeFile.displayName)")
    }

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
        guard let engraved = activeFile.engravedText else {
            engraving = nil
            linkOffsets = []
            return
        }
        let map = EngravingMap(engraved: engraved, current: editor.text)
        engraving = map
        linkOffsets = activeFile.linkedPositions
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
        canvas.highlight(positions, path: activeFile.url.path, reveal: reveal)
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
            // ⎋ with nothing selected disarms (ends mouse entry).
            if !hasSelection, noteInput.armedDuration != nil {
                noteInput.arm(nil)
                updateInputStatus()
                return
            }
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
        if noteInput.armedDuration == nil { canvas.clearGhost() }
        updateHints()
    }

    // MARK: Status

    private func updateStatus() {
        let lily = score.installation.map { "LilyPond \($0.version)" } ?? "LilyPond —"
        var note: String?
        if let declared = score.declaredVersion, let v = score.installation?.version, declared != v {
            note = "Score declares \(declared); compiling with \(v)"
        }
        if let f = score.unlinkedFiles.first {
            // Never fail silently: say which music can't be clicked, and why.
            note = "\(f.displayName) has notes but no point-and-click links"
        }
        statusBar.set(status: score.status, detail: firstErrorText(), zoom: canvas.zoom, toolchain: lily, note: note)
        updateHints()
    }

    private func firstErrorText() -> String? {
        guard let d = score.files.lazy.flatMap({ $0.diagnostics }).first(where: { $0.severity == .error || $0.severity == .fatal }) else { return nil }
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
        if noteInput.armedDuration != nil { hints.insert("Click a staff to place a note", at: 0) }
        if case .errors = score.status { hints.insert("Errors are underlined in the source", at: 0) }
        statusBar.setHints(Array(hints.prefix(3)))
    }

    private func showDiagnostics() {
        let text = editor.text
        let source = SourceText(activeFile.compiledText ?? text)
        let map = EngravingMap(engraved: activeFile.compiledText ?? text, current: text)
        let current = SourceText(text)
        let ranges: [(NSRange, NSColor)] = activeFile.diagnostics.compactMap { d in
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

    @objc func switchPane(_ sender: Any?) { run("pane.focusNext") }

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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        saveLayout()
        score.close()
        (NSApp.delegate as? PondsideAppDelegate)?.windowDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        score.revalidate()
    }

    /// ⌘Z from either pane undoes the visible file's edits, score and text alike.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        activeFile.undoManager
    }
}

extension DocumentWindowController: ScoreCanvasDelegate {
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool) {
        guard let link else {
            perform(.clearSelection)
            return
        }
        guard let file = score.file(for: link.path) else {
            statusBar.flash("That object comes from \((link.path as NSString).lastPathComponent), outside this score's files")
            return
        }
        if file !== activeFile {
            showFile(file)
            statusBar.flash("Editing \(file.displayName)")
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

    func canvasClickedUnlinkedMusic(_ canvas: ScoreCanvasView) {
        // DESIGN.md M2.1 B: explain, don't silently deselect.
        statusBar.flash("That object has no source link — it may come from Scheme, a music function, or LilyPond itself")
    }

    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation]) {
        // A rectangle edits one file: the one most of its links come from.
        var counts: [ObjectIdentifier: (SourceFile, Int)] = [:]
        for l in links {
            guard let f = score.file(for: l.path) else { continue }
            counts[ObjectIdentifier(f), default: (f, 0)].1 += 1
        }
        guard let target = counts.values.max(by: { $0.1 < $1.1 })?.0 else { return }
        if target !== activeFile { showFile(target) }
        let offsets = links.filter { target.matches(path: $0.path) }.compactMap { currentOffset(of: $0) }
        let events = Set(offsets.compactMap { tree.eventIndex(at: $0) })
        guard !events.isEmpty else { return }
        // A rectangle selects the contiguous source span it covers.
        selectEvents(Array(events))
    }

    func canvas(_ canvas: ScoreCanvasView, handleKey event: NSEvent) -> Bool {
        handleScoreKey(event)
    }

    func canvasWantsMouseEntry(_ canvas: ScoreCanvasView) -> Bool {
        noteInput.armedDuration != nil
    }

    /// Mouse entry: the staff position is the pitch, the armed duration the
    /// value, and the note goes after whatever stands to the left.
    func canvas(_ canvas: ScoreCanvasView, clickedStaff staff: Staff, at point: Point, on page: EngravedPage) {
        var anchors: [MouseEntry.Anchor] = []
        var owners: [(file: SourceFile, event: Int)] = []
        for file in score.files where file.hasNotes {
            guard let engraved = file.engravedText else { continue }
            let map = EngravingMap(engraved: engraved, current: file.text)
            let text = file.text
            let found = MouseEntry.anchors(on: staff, page: page, tree: file.tree, linkedFrom: { file.matches(path: $0) }) { p in
                map.engravedOffset(of: p).map { OffsetConversion.utf8(fromUTF16: map.currentOffset(forEngraved: $0), in: text) }
            }
            for a in found {
                owners.append((file, a.ref))
                anchors.append(MouseEntry.Anchor(bounds: a.bounds, pitch: a.pitch, ref: owners.count - 1))
            }
        }
        switch MouseEntry.target(click: point, staff: staff, anchors: anchors) {
        case .failure(.nothingBefore):
            statusBar.flash("Click to the right of a note: mouse entry places the new note after it")
            NSSound.beep()
        case .failure(.uncalibrated):
            statusBar.flash("Mouse entry reads the clef from the notes on a staff; type the first one")
            NSSound.beep()
        case .success(let target):
            let owner = owners[target.after]
            if owner.file !== activeFile { showFile(owner.file) }
            guard tree.events[owner.event].acceptsNoteEntry else {
                statusBar.flash("Notes can't be inserted there; type them in the source")
                NSSound.beep()
                return
            }
            apply(ScoreEditor(tree).insert(step: target.step, after: owner.event, duration: noteInput.armedDuration,
                                           octave: target.octave))
        }
    }
}

extension DocumentWindowController: ScoreDocumentDelegate {
    func document(_ document: ScoreDocument, didReloadFromDisk file: SourceFile) {
        editor.mergeExternal(file.text, into: file.url)
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        statusBar.flash("Reloaded \(file.displayName) — it changed on disk")
    }

    func document(_ document: ScoreDocument, hasConflictIn file: SourceFile, diskText: String) {
        guard let window, pendingConflict == nil else {
            pendingConflict = (file, diskText)
            return
        }
        pendingConflict = (file, diskText)
        let alert = NSAlert()
        alert.messageText = "\(file.displayName) changed on disk while you were typing"
        alert.informativeText = "Another program edited the file. Whichever version you don't keep is saved to ~/Library/Application Support/Pondside/Recovery, so nothing is lost."
        alert.addButton(withTitle: "Use the File on Disk")
        alert.addButton(withTitle: "Keep My Edits")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let pending = self.pendingConflict else { return }
            self.pendingConflict = nil
            self.score.resolveConflict(in: pending.file, keepMine: response == .alertSecondButtonReturn, diskText: pending.disk)
        }
    }

    func documentStatusDidChange(_ document: ScoreDocument) {
        updateStatus()
    }

    func documentFilesDidChange(_ document: ScoreDocument) {
        if !document.files.contains(where: { $0 === activeFile }) {
            showFile(document.root)
        } else {
            rebuildFileMenu()
        }
    }

    func documentDidEngrave(_ document: ScoreDocument) {
        let first = canvas.pages.isEmpty
        canvas.setPages(score.pages)
        if first { canvas.fitWidth() }
        compilerOutput.show(score.lastLog)
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        showDiagnostics()
        updateStatus()
    }
}

// MARK: - Commands, chords, palette and panes (M3)

/// A reference cell for palette providers, which recompute their rows on
/// each keystroke and must hand the chosen one back.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

extension DocumentWindowController: CommandResponder {
    @objc func performCommand(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.commandID else { return }
        run(id)
    }

    var commandContext: CommandContext {
        let responder = window?.firstResponder
        let focus: CommandContext.Focus = responder === canvas ? .score : responder === editor.textView ? .source : .other
        var errors = false
        if case .errors = score.status { errors = true }
        return CommandContext(focus: focus, hasSelection: hasSelection, durationArmed: noteInput.armedDuration != nil,
                              hasErrors: errors, fileCount: score.files.count)
    }

    /// Runs a catalog command. Menus, chords and the palette all end here.
    func run(_ id: CommandID) {
        let center = CommandCenter.shared
        if let spec = center.spec(id), !spec.isAvailable(in: commandContext) {
            statusBar.flash(Self.unavailableMessage(spec))
            NSSound.beep()
            return
        }
        center.palette.noteUsed(id)
        let selected = targets().events
        let pitched = selected.filter { tree.events[$0].isPitched }
        let editor = ScoreEditor(tree)
        switch id.rawValue {
        case "file.exportPDF": exportPDF(nil)
        case "file.reveal": revealInFinder(nil)
        case "file.close": window?.performClose(nil)

        case "go.file": showFilePicker()
        case "go.nextFile": nextFile(nil)
        case "go.previousFile": previousFile(nil)
        case "go.error": goToError()
        case "go.first":
            if let i = tree.events.firstIndex(where: { $0.acceptsNoteEntry }) { selectEvents([i]) }
        case "go.last":
            if let i = tree.events.lastIndex(where: { $0.acceptsNoteEntry }) { selectEvents([i]) }
        case "go.next": perform(.select(step: 1, extend: false))
        case "go.previous": perform(.select(step: -1, extend: false))

        case "add.slur": apply(editor.toggleSpan(open: "(", close: ")", events: pitched, name: "Slur"))
        case "add.beam": apply(editor.toggleSpan(open: "[", close: "]", events: pitched, name: "Beam"))
        case "add.crescendo": apply(editor.toggleSpan(open: "\\<", close: "\\!", events: selected, name: "Crescendo"))
        case "add.decrescendo": apply(editor.toggleSpan(open: "\\>", close: "\\!", events: selected, name: "Decrescendo"))
        case "add.tie": apply(editor.togglePostEvent("~", events: pitched))
        case "add.staccato": apply(editor.togglePostEvent("-.", events: pitched))
        case "add.accent": apply(editor.togglePostEvent("->", events: pitched))
        case "add.tenuto": apply(editor.togglePostEvent("--", events: pitched))
        case "add.fermata": apply(editor.togglePostEvent("\\fermata", events: selected))
        case "add.dynamic": showDynamicPicker(events: selected)
        case "add.tuplet":
            guard let edit = editor.wrapTuplet(events: selected) else {
                statusBar.flash("A tuplet needs a selection inside one { } block")
                NSSound.beep()
                return
            }
            apply(edit)
        case "add.note": statusBar.flash("Type a–g with the score focused: the note goes after the selection")
        case "add.rest": insert(step: nil)
        case "add.mouse": statusBar.flash("Type a duration (4, 8, 16…) with nothing selected, then click a staff")

        case "edit.undo": activeFile.undoManager.undo()
        case "edit.redo": activeFile.undoManager.redo()
        case "edit.delete": perform(.delete)
        case "edit.source": perform(.editSource)
        case "edit.find":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            window?.makeFirstResponder(self.editor.textView)
            self.editor.textView.performFindPanelAction(item)
        case "edit.selectAll": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "edit.up": perform(.move(.step(1)))
        case "edit.down": perform(.move(.step(-1)))
        case "edit.duration": statusBar.flash("Type 1 2 4 8 16 32 in the score: it changes the selection, or arms the next note")
        case "edit.dot": perform(.toggleDot)
        case "edit.disarm":
            noteInput.arm(nil)
            updateInputStatus()

        case "view.zoomIn": zoomIn(nil)
        case "view.zoomOut": zoomOut(nil)
        case "view.actualSize": actualSize(nil)
        case "view.fitWidth": zoomToFitWidth(nil)
        case "view.fullScreen": window?.toggleFullScreen(nil)

        case "pane.focusNext":
            syncFocusedPane()
            var l = panes.layout
            l.focusNext()
            focusPane(l.focused)
        case "pane.cycleNext": cyclePane(forward: true)
        case "pane.cyclePrevious": cyclePane(forward: false)
        case "workspace.save": saveWorkspace()
        case "workspace.open": showWorkspacePicker()

        case "help.palette": showCommandPalette(onlyAvailable: false, placeholder: "Type a command — two letters are usually enough")
        case "help.context": showCommandPalette(onlyAvailable: true, placeholder: "What can I do here?")
        case "help.keys": showCommandPalette(onlyAvailable: false, placeholder: "Every command and its keys")

        default:
            let raw = id.rawValue
            if raw.hasPrefix("pane.show."), let c = PaneContent(rawValue: String(raw.dropFirst("pane.show.".count))) {
                showInFocusedPane(c)
            } else if raw.hasPrefix("workspace.preset"), let n = Int(raw.dropFirst("workspace.preset".count)),
                      PaneLayout.presets.indices.contains(n - 1) {
                applyLayout(PaneLayout.presets[n - 1])
            } else {
                (NSApp.delegate as? PondsideAppDelegate)?.runAppCommand(id)
            }
        }
    }

    private static func unavailableMessage(_ spec: CommandSpec) -> String {
        switch spec.requires {
        case .selection: return "\(spec.title) needs a selection: click a note, or walk with ←→"
        case .errors: return "No errors: the score compiles cleanly"
        case .severalFiles: return "This score is a single file"
        case .scoreFocus: return "\(spec.title) works in the score: ⌘J to focus it"
        case .always: return spec.title
        }
    }

    // MARK: Leader chords

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.intercept(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Window-wide keys: the leader (Space in the score, ⌥Space anywhere —
    /// ⌃Space belongs to macOS input-source switching),
    /// the keys of a chord in progress, and ⌥ for the key reveal.
    private func intercept(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            help.optionChanged(isDown: flags == .option)
            return false
        }
        help.optionChanged(isDown: false)
        let keymap = CommandCenter.shared.keymap
        if chord.isActive {
            if event.keyCode == 53 {
                chord.cancel()
                statusBar.endChord()
                return true
            }
            guard let c = event.characters?.first else { return true }
            handle(chord.feed(c, keymap))
            return true
        }
        let isSpace = event.keyCode == 49
        let leader = isSpace && (flags == .option || (flags.isEmpty && window.firstResponder === canvas && !noteInput.isBuffering))
        guard leader else { return false }
        handle(chord.begin(keymap))
        return true
    }

    private func handle(_ outcome: ChordRecognizer.Outcome) {
        switch outcome {
        case .pending(let next):
            let typed = (["␣"] + (chord.typed ?? []).map { String($0) }).joined(separator: " ")
            statusBar.showChord(typed: typed, continuations: next)
        case .command(let id):
            statusBar.endChord()
            run(id)
        case .unbound(let keys):
            statusBar.endChord()
            statusBar.flash("\(keys) isn't bound. ⌘K finds any command")
            NSSound.beep()
        }
    }

    // MARK: Palette

    private func showCommandPalette(onlyAvailable: Bool, placeholder: String) {
        guard let window else { return }
        let context = commandContext
        let items = Box<[CommandPalette.Item]>([])
        let panel = PalettePanel(placeholder: placeholder, provider: { query in
            items.value = CommandCenter.shared.palette.items(for: query, in: context, onlyAvailable: onlyAvailable)
            return items.value.map {
                PaletteRow(title: $0.spec.title, detail: $0.spec.gloss, hint: $0.hint, enabled: $0.available, matched: $0.matched)
            }
        }, onChoose: { [weak self] i in
            guard items.value.indices.contains(i) else { return }
            self?.run(items.value[i].spec.id)
        })
        panel.present(over: window)
    }

    /// A palette over plain choices, fuzzy-matched by title.
    private func showPicker(placeholder: String, choices: [(title: String, detail: String?)], choose: @escaping (Int) -> Void) {
        guard let window else { return }
        let order = Box<[Int]>([])
        let panel = PalettePanel(placeholder: placeholder, provider: { query in
            let scored = choices.enumerated().compactMap { i, c -> (Int, FuzzyMatch.Result)? in
                FuzzyMatch.match(query, in: c.title).map { (i, $0) }
            }.sorted { $0.1.score > $1.1.score || ($0.1.score == $1.1.score && $0.0 < $1.0) }
            order.value = scored.map(\.0)
            return scored.map { PaletteRow(title: choices[$0.0].title, detail: choices[$0.0].detail, matched: $0.1.positions) }
        }, onChoose: { i in
            guard order.value.indices.contains(i) else { return }
            choose(order.value[i])
        })
        panel.present(over: window)
    }

    private func showFilePicker() {
        let rootDir = score.url.deletingLastPathComponent().path + "/"
        let files = score.files
        showPicker(placeholder: "Go to file", choices: files.map { f in
            let path = f.url.path.hasPrefix(rootDir) ? String(f.url.path.dropFirst(rootDir.count)) : f.url.path
            return (title: f.displayName, detail: (f.hasNotes ? path : path + " · no notes") as String?)
        }) { [weak self] i in
            guard let self, files.indices.contains(i) else { return }
            self.showFile(files[i])
        }
    }

    private static let dynamics = ["ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "fp", "sf", "sfz", "rfz"]

    private func showDynamicPicker(events: [Int]) {
        showPicker(placeholder: "Dynamic", choices: Self.dynamics.map { (title: "\\" + $0, detail: nil as String?) }) { [weak self] i in
            guard let self else { return }
            self.apply(ScoreEditor(self.tree).togglePostEvent("\\" + Self.dynamics[i], events: events))
        }
    }

    private func goToError() {
        let errors = score.files.flatMap { f in
            f.diagnostics.filter { $0.severity == .error || $0.severity == .fatal }.map { (file: f, diagnostic: $0) }
        }
        guard !errors.isEmpty else { return }
        let caret = editor.textView.selectedRange().location
        // The next error after the caret in this file, else the first elsewhere.
        let here = errors.filter { $0.file === activeFile }
            .compactMap { e in Self.location(of: e.diagnostic, in: e.file).map { (e, $0) } }
            .sorted { $0.1 < $1.1 }
        let target = here.first { $0.1 > caret }?.0 ?? errors.first { $0.file !== activeFile } ?? here.first?.0 ?? errors[0]
        if target.file !== activeFile { showFile(target.file) }
        guard let loc = Self.location(of: target.diagnostic, in: target.file) else { return }
        window?.makeFirstResponder(editor.textView)
        editor.select(NSRange(location: loc, length: 0))
        statusBar.flash(target.diagnostic.message)
    }

    /// Where a diagnostic points in the file's current text (UTF-16).
    private static func location(of d: Diagnostic, in f: SourceFile) -> Int? {
        let engraved = f.compiledText ?? f.text
        let source = SourceText(engraved)
        guard let p = d.position(in: source), let i = source.index(of: p) else { return nil }
        return EngravingMap(engraved: engraved, current: f.text).currentOffset(forEngraved: source.utf16Offset(of: i))
    }

    // MARK: Panes

    private static let layoutKey = "Pondside.layout"
    private static let workspacesKey = "Pondside.workspaces"
    /// Content that exists today; the rest shows a placeholder naming its milestone.
    private static let builtContent: [PaneContent] = [.score, .lilypond, .compilerOutput, .terminal]

    private static func savedLayout() -> PaneLayout {
        if let data = UserDefaults.standard.data(forKey: layoutKey),
           let layout = try? JSONDecoder().decode(PaneLayout.self, from: data), !layout.contents.isEmpty {
            return layout
        }
        return PaneLayout.presets[0]
    }

    private func saveLayout() {
        panes.captureFractions()
        if let data = try? JSONEncoder().encode(panes.layout) { UserDefaults.standard.set(data, forKey: Self.layoutKey) }
    }

    private func makeContent(_ content: PaneContent) -> NSView {
        switch content {
        case .score: return canvasScroll
        case .lilypond: return editorPane
        case .compilerOutput:
            compilerOutput.show(score.lastLog)
            return compilerOutput
        case .terminal: return TerminalPane(directory: score.url.deletingLastPathComponent())
        default: return PanePlaceholder(content)
        }
    }

    private func responder(for content: PaneContent) -> NSView {
        switch content {
        case .score: return canvas
        case .lilypond: return editor.textView
        case .terminal: return (panes.view(for: .terminal) as? TerminalPane)?.responder ?? panes.view(for: .terminal)
        default: return panes.view(for: content)
        }
    }

    private func syncFocusedPane() {
        if let i = panes.paneIndex(containing: window?.firstResponder as? NSView) { panes.setFocused(i) }
    }

    private func focusPane(_ i: Int) {
        panes.setFocused(i)
        if let c = panes.layout.focusedContent { window?.makeFirstResponder(responder(for: c)) }
    }

    private func applyLayout(_ layout: PaneLayout) {
        panes.apply(layout)
        focusPane(layout.focused)
        saveLayout()
    }

    private func cyclePane(forward: Bool) {
        syncFocusedPane()
        var l = panes.layout
        l.cycle(forward: forward, available: Self.builtContent)
        applyLayout(l)
        if let c = l.focusedContent { statusBar.flash("\(c.title) · ⌃⇥ next, ⌃1–⌃0 jump") }
    }

    private func showInFocusedPane(_ content: PaneContent) {
        syncFocusedPane()
        var l = panes.layout
        l.show(content)
        applyLayout(l)
    }

    private func loadWorkspaces() -> Workspaces {
        guard let data = UserDefaults.standard.data(forKey: Self.workspacesKey),
              let w = try? JSONDecoder().decode(Workspaces.self, from: data) else { return Workspaces() }
        return w
    }

    private func saveWorkspace() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Name this arrangement of panes. Open it again with ␣ w o."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Orchestration"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.panes.captureFractions()
            var w = self.loadWorkspaces()
            w.save(self.panes.layout, as: name)
            if let data = try? JSONEncoder().encode(w) { UserDefaults.standard.set(data, forKey: Self.workspacesKey) }
            self.statusBar.flash("Saved workspace “\(name)”")
        }
    }

    private func showWorkspacePicker() {
        let saved = loadWorkspaces().saved
        let all = PaneLayout.presets + saved
        showPicker(placeholder: "Open workspace", choices: all.map { l in
            (title: l.name, detail: l.contents.map(\.title).joined(separator: " · ") as String?)
        }) { [weak self] i in
            guard all.indices.contains(i) else { return }
            self?.applyLayout(all[i])
        }
    }
}
