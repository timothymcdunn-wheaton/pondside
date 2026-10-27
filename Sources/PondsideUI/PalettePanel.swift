import AppKit
import PondsideCore

/// One line in the palette.
struct PaletteRow {
    var title: String
    var detail: String?
    /// The keys that run it, right-aligned: the palette teaches chords.
    var hint: String?
    var enabled = true
    /// Character offsets of `title` that matched the query.
    var matched: [Int] = []
}

/// The floating fuzzy palette: ⌘K for commands, ⌘/ for what applies
/// here, and pickers (files, dynamics) built on the same surface.
/// Translucent floating chrome, as the visual budget allows.
@MainActor
final class PalettePanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [PaletteRow] = []
    private let provider: (String) -> [PaletteRow]
    private let onChoose: (Int) -> Void
    private static let rowHeight: CGFloat = 44
    private static let width: CGFloat = 620

    /// - Parameters:
    ///   - provider: rows for a query, best first.
    ///   - onChoose: called with the index of the chosen row (after closing).
    init(placeholder: String, provider: @escaping (String) -> [PaletteRow], onChoose: @escaping (Int) -> Void) {
        self.provider = provider
        self.onChoose = onChoose
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        appearance = NSAppearance(named: .darkAqua)

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        glass.layer?.masksToBounds = true
        contentView = glass

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: Theme.bodySize + 3)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.text
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for v in [field, separator, scroll] as [NSView] { glass.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: glass.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -18),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -6),
        ])
        refresh()
    }

    override var canBecomeKey: Bool { true }

    /// Shows the palette near the top of `parent`, centred.
    func present(over parent: NSWindow) {
        let f = parent.frame
        setFrameTopLeftPoint(NSPoint(x: f.midX - Self.width / 2, y: f.maxY - 90))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    private func refresh() {
        rows = provider(field.stringValue)
        table.reloadData()
        if let first = rows.firstIndex(where: \.enabled) ?? (rows.isEmpty ? nil : 0) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
        let visible = CGFloat(min(max(rows.count, 1), 9))
        var frame = self.frame
        let height = 14 + 24 + 12 + 1 + 4 + visible * Self.rowHeight + 6
        frame.origin.y += frame.height - height
        frame.size.height = height
        setFrame(frame, display: true)
    }

    private func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func choose(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        dismiss()
        onChoose(row)
    }

    @objc private func rowClicked(_ sender: Any?) { choose(table.clickedRow) }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        let r = min(max(table.selectedRow + step, 0), rows.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.id, owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.show(rows[row])
        return cell
    }
}

@MainActor
private final class PaletteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PaletteCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        detail.font = Theme.secondaryFont
        detail.textColor = Theme.secondaryText
        hint.font = .monospacedSystemFont(ofSize: Theme.secondarySize, weight: .medium)
        hint.textColor = Theme.accent
        hint.alignment = .right
        for l in [title, detail, hint] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: PaletteRow) {
        let color = row.enabled ? Theme.text : Theme.secondaryText
        let s = NSMutableAttributedString(string: row.title, attributes: [.font: Theme.bodyFont, .foregroundColor: color])
        let chars = Array(row.title)
        var utf16 = [Int](repeating: 0, count: chars.count + 1)
        for (i, c) in chars.enumerated() { utf16[i + 1] = utf16[i] + c.utf16.count }
        for i in row.matched where i < chars.count {
            s.addAttributes([.font: NSFont.systemFont(ofSize: Theme.bodySize, weight: .bold)],
                            range: NSRange(location: utf16[i], length: utf16[i + 1] - utf16[i]))
        }
        title.attributedStringValue = s
        detail.stringValue = row.enabled ? (row.detail ?? "") : (row.detail.map { $0 + " — not available here" } ?? "Not available here")
        hint.stringValue = row.hint ?? ""
    }
}
