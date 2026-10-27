import AppKit
import PondsideTiming

/// Every electronics cue: where it is in bars and beats, when it happens,
/// and whether the patch handles it. Sortable, keyboard-navigable; ↩ or a
/// double-click jumps to the cue in the source.
@MainActor
final class CueInspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let summary = NSTextField(labelWithString: "")
    private let table = CueTable()
    private let scroll = NSScrollView()
    private var cues: [CueSheet.Cue] = []
    private var rows: [CueSheet.Cue] = []
    private var handled: Set<String> = []
    private var scoreFolder: URL?
    /// Called with the cue to reveal in the source.
    var onJump: ((CueSheet.Cue) -> Void)?

    private enum Column: String, CaseIterable {
        case index = "#", bar = "Bar", beat = "Beat", time = "Time", name = "Cue", handler = "Handler"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        summary.font = Theme.secondaryFont
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false

        for c in Column.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.rawValue
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: true)
            switch c {
            case .index, .bar, .beat: col.width = 48
            case .time: col.width = 90
            case .name: col.width = 140
            case .handler: col.width = 160
            }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.editorBackground
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 24
        table.target = self
        table.doubleAction = #selector(jump(_:))
        table.onReturn = { [weak self] in self?.jump(nil) }
        table.style = .plain
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summary)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(nil, scoreFolder: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The view that takes the keyboard.
    var responder: NSView { table }

    func show(_ sheet: CueSheet?, scoreFolder: URL?) {
        self.scoreFolder = scoreFolder
        cues = sheet?.cues ?? []
        handled = scoreFolder.map { Self.handlers(in: $0) } ?? []
        sort()
        guard let sheet else {
            summary.stringValue = "No compile yet"
            return
        }
        var parts = ["\(cues.count) cue\(cues.count == 1 ? "" : "s")"]
        if let d = sheet.duration { parts.append("piece \(Self.timecode(d))") }
        let missing = cues.filter { !handled.contains($0.handler) }.count
        if !cues.isEmpty {
            parts.append(missing == 0 ? "every cue has a handler" : "\(missing) without a handler in any .scd here")
        }
        parts += sheet.warnings
        summary.stringValue = parts.joined(separator: "  ·  ")
    }

    /// Handler names defined in the SuperCollider files beside the score
    /// (and one folder down): `p.on(\name, …)` or any `\name` symbol key.
    static func handlers(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        var files: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for u in top {
            if u.pathExtension == "scd" { files.append(u) }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "scd" }
            }
        }
        var names = Set<String>()
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains(".on(\\") && !line.hasPrefix("//") {
                guard let r = line.range(of: ".on(\\") else { continue }
                names.insert(String(line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }))
            }
        }
        return names
    }

    static func timecode(_ s: Double) -> String {
        let ms = Int((s * 1000).rounded())
        return String(format: "%d:%02d.%03d", ms / 60000, (ms / 1000) % 60, ms % 1000)
    }

    private func sort() {
        let d = table.sortDescriptors.first
        let key = d?.key ?? Column.index.rawValue
        let ascending = d?.ascending ?? true
        rows = cues.sorted { a, b in
            let less: Bool
            switch Column(rawValue: key) ?? .index {
            case .index, .time: less = a.index < b.index
            case .bar: less = (a.position.measure, a.index) < (b.position.measure, b.index)
            case .beat: less = (a.position.beat ?? 0, a.index) < (b.position.beat ?? 0, b.index)
            case .name: less = (a.name, a.index) < (b.name, b.index)
            case .handler: less = (handled.contains(a.handler) ? 1 : 0, a.index) < (handled.contains(b.handler) ? 1 : 0, b.index)
            }
            return ascending ? less : !less
        }
        table.reloadData()
    }

    @objc private func jump(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r) else { return }
        onJump?(rows[r])
    }


    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { sort() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id) else { return nil }
        let cue = rows[row]
        let label = NSTextField(labelWithString: "")
        label.font = column == .time || column == .handler ? Theme.monoFont : Theme.bodyFont
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        switch column {
        case .index: label.stringValue = "\(cue.index)"
        case .bar: label.stringValue = "\(cue.position.measure)"
        case .beat: label.stringValue = cue.position.beat.map { $0 == $0.rounded() ? "\(Int($0))" : String(format: "%.2f", $0) } ?? "—"
        case .time: label.stringValue = Self.timecode(cue.seconds)
        case .name: label.stringValue = cue.name
        case .handler:
            let has = handled.contains(cue.handler)
            label.stringValue = (has ? "" : "⚠︎ ") + "\\" + cue.handler
            label.textColor = has ? Theme.secondaryText : Theme.warning
            label.toolTip = has ? "Handled in the patch" : "No p.on(\\\(cue.handler), …) in the .scd files here: pondside handlers adds a stub"
        }
        return label
    }
}

/// ↩ jumps to the selected cue, like a double-click.
@MainActor
private final class CueTable: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}
