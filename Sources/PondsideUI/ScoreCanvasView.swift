import AppKit
import PondsideCore
import PondsideEngrave

@MainActor
protocol ScoreCanvasDelegate: AnyObject {
    /// The user clicked a linked glyph (or empty paper: nil).
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool)
    /// The user dragged a selection rectangle over these links.
    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation])
    /// The user clicked music that carries no point-and-click link.
    func canvasClickedUnlinkedMusic(_ canvas: ScoreCanvasView)
    /// A key pressed while the score has focus. Return true if handled.
    func canvas(_ canvas: ScoreCanvasView, handleKey event: NSEvent) -> Bool
    /// Whether clicking an empty staff places a note (a duration is armed).
    func canvasWantsMouseEntry(_ canvas: ScoreCanvasView) -> Bool
    /// A click on empty staff space while mouse entry is wanted.
    func canvas(_ canvas: ScoreCanvasView, clickedStaff staff: Staff, at point: Point, on page: EngravedPage)
    /// Mouse entry was wanted but the click found no staff; `stavesOnPage`
    /// is how many staves the page has (0: none could be recognised).
    func canvas(_ canvas: ScoreCanvasView, missedStaffWith stavesOnPage: Int)
}

/// The score surface: pages floating on the dark field.
///
/// Each page is its own layer-backed view so invalidation, cross-fades and
/// layer sizes stay per page. Drawing is Core Graphics into Core Animation
/// layers, which the window server composites on the GPU (see DESIGN.md on
/// why this is preferred to a hand-written Metal rasteriser for now).
@MainActor
final class ScoreCanvasView: NSView {
    weak var delegate: ScoreCanvasDelegate?

    private(set) var pages: [RenderedPage] = []
    private var pageViews: [PageView] = []
    private(set) var zoom: CGFloat = 1.0
    var lightsOut = false {
        didSet { pageViews.forEach { $0.lightsOut = lightsOut } }
    }
    var onZoomChange: ((CGFloat) -> Void)?

    private let margin: CGFloat = 40
    private let gap: CGFloat = 28
    private static let pointsPerMM: CGFloat = 72 / 25.4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Called when the canvas gains or loses the keyboard, so the window can
    /// show where keys go.
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    /// Replaces the pages, cross-fading so a recompile never flickers.
    func setPages(_ newPages: [EngravedPage]) {
        lastInserted = nil
        let rendered = newPages.map(RenderedPage.init)
        let animate = !pages.isEmpty
        pages = rendered
        while pageViews.count > rendered.count { pageViews.removeLast().removeFromSuperview() }
        while pageViews.count < rendered.count {
            let v = PageView(frame: .zero)
            v.owner = self
            v.lightsOut = lightsOut
            addSubview(v)
            pageViews.append(v)
        }
        for (v, p) in zip(pageViews, rendered) {
            if animate { v.crossFade() }
            v.rendered = p
        }
        relayout()
    }

    func setZoom(_ z: CGFloat, anchor: NSPoint? = nil) {
        let clamped = min(max(z, 0.25), 6)
        guard abs(clamped - zoom) > 0.001 else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let focus = anchor ?? NSPoint(x: visible.midX, y: visible.midY)
        let fx = bounds.width > 0 ? focus.x / bounds.width : 0.5
        let fy = bounds.height > 0 ? focus.y / bounds.height : 0
        zoom = clamped
        relayout()
        // Keep the focus point stable while zooming.
        let newFocus = NSPoint(x: fx * bounds.width, y: fy * bounds.height)
        scroll(NSPoint(x: newFocus.x - (focus.x - visible.minX), y: newFocus.y - (focus.y - visible.minY)))
        onZoomChange?(zoom)
    }

    /// Zoom so the widest page fills the visible width.
    func fitWidth() {
        guard let widest = pages.map({ CGFloat($0.page.widthMM) }).max(),
              let clip = enclosingScrollView?.contentView.bounds.width else { return }
        setZoom((clip - 2 * margin) / (widest * Self.pointsPerMM))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPageViews()
    }

    private func relayout() {
        let sizes = pages.map { pageSize($0) }
        let contentWidth = (sizes.map(\.width).max() ?? 0) + 2 * margin
        let contentHeight = sizes.reduce(margin) { $0 + $1.height + gap } - gap + margin
        let clip = enclosingScrollView?.contentView.bounds.size ?? .zero
        setFrameSize(NSSize(width: max(contentWidth, clip.width), height: max(contentHeight, clip.height)))
        layoutPageViews()
    }

    private func layoutPageViews() {
        var y = margin
        for (v, p) in zip(pageViews, pages) {
            let size = pageSize(p)
            v.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y += size.height + gap
        }
    }

    private func pageSize(_ p: RenderedPage) -> NSSize {
        NSSize(width: (CGFloat(p.page.widthMM) * Self.pointsPerMM * zoom).rounded(),
               height: (CGFloat(p.page.heightMM) * Self.pointsPerMM * zoom).rounded())
    }

    // MARK: Highlighting

    /// Highlights every graphic produced by the given source positions.
    /// The highlight is an overlay; the music itself is never recoloured.
    func highlight(_ positions: Set<SourcePosition>, path: String?, reveal: Bool) {
        var firstRect: NSRect?
        var sameFile: [String: Bool] = [:]
        for v in pageViews {
            guard let page = v.rendered?.page else { continue }
            let matches = page.graphics.filter { g in
                guard !v.removed.contains(g) else { return false }
                guard let link = g.link, positions.contains(link.position) else { return false }
                guard let path else { return true }
                if let known = sameFile[link.path] { return known }
                let same = PathMatching.same(link.path, path)
                sameFile[link.path] = same
                return same
            }
            v.highlights = matches.map(\.bounds)
            if firstRect == nil, let r = EngravedPage.bounds(of: matches) {
                firstRect = convert(v.viewRect(for: r), from: v)
            }
        }
        if reveal, let r = firstRect, !visibleRect.contains(r) {
            scrollToVisible(r.insetBy(dx: -80, dy: -80))
        }
    }

    // MARK: Events

    fileprivate func pageView(_ v: PageView, clickedAt p: Point, event: NSEvent) {
        window?.makeFirstResponder(self)
        let tolerance = 0.3 / max(zoom, 0.5)
        let link = v.rendered?.page.hitTest(p, tolerance: tolerance, excluding: v.removed)?.link
        if link == nil, let page = v.rendered?.page, delegate?.canvasWantsMouseEntry(self) == true {
            guard let staff = page.staff(at: p, among: v.staves) else {
                delegate?.canvas(self, missedStaffWith: v.staves.count)
                return
            }
            v.ghost = nil
            delegate?.canvas(self, clickedStaff: staff, at: p, on: page)
            return
        }
        if link == nil, let page = v.rendered?.page,
           page.graphics.contains(where: { $0.bounds.insetBy(-tolerance).contains(p) && $0.bounds.width < page.viewBox.width * 0.5 }) {
            // Something is there, but it can't lead back to the source.
            delegate?.canvasClickedUnlinkedMusic(self)
            return
        }
        delegate?.canvas(self, didClick: link, extending: event.modifierFlags.contains(.shift))
    }

    /// Mouse entry preview: a ghost notehead where a click would place one.
    fileprivate func pageView(_ v: PageView, hoverAt p: Point?) {
        guard let p, delegate?.canvasWantsMouseEntry(self) == true, let page = v.rendered?.page,
              page.hitTest(p, tolerance: 0.3 / max(zoom, 0.5)) == nil,
              let staff = page.staff(at: p, among: v.staves) else {
            v.ghost = nil
            return
        }
        v.ghost = Ghost(staff: staff, x: p.x, position: staff.position(ofY: p.y),
                        glyph: sampleGlyph(on: staff, page: page, near: p.x))
    }

    /// A real notehead on the staff to use as the mouse-entry template. The
    /// nearest one is best: its spacing and glyph weight belong to this staff.
    private func sampleGlyph(on staff: Staff, page: EngravedPage, near x: Double) -> NoteGlyph? {
        let band = staff.band()
        var byPosition: [SourcePosition: [Graphic]] = [:]
        for g in page.graphics {
            guard let link = g.link, band.contains(Point(g.bounds.midX, g.bounds.midY)) else { continue }
            byPosition[link.position, default: []].append(g)
        }
        var best: NoteGlyph?
        for graphics in byPosition.values {
            guard let glyph = EngravedPage.noteGlyph(among: graphics, space: staff.space) else { continue }
            if best == nil || abs(glyph.head.midX - x) < abs(best!.head.midX - x) { best = glyph }
        }
        return best
    }

    /// Provisional rendering: ghost noteheads where the given notes are
    /// moving, drawn until the next engraving replaces the pages. The music
    /// itself is never redrawn or recoloured.
    func provisionalShift(_ positions: Set<SourcePosition>, path: String, halfSpaces: Int) {
        guard halfSpaces != 0 else { return }
        for v in pageViews {
            guard let page = v.rendered?.page else { continue }
            var byPosition: [SourcePosition: [Graphic]] = [:]
            for g in page.graphics {
                guard let link = g.link, positions.contains(link.position), PathMatching.same(link.path, path) else { continue }
                byPosition[link.position, default: []].append(g)
            }
            var ghosts = v.provisional
            for (_, graphics) in byPosition {
                guard let first = graphics.first,
                      let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY), among: v.staves),
                      let glyph = EngravedPage.noteGlyph(among: graphics, space: staff.space) else { continue }
                // Accumulate: two quick ↑ before a recompile move the ghost twice.
                let base = ghosts.first { abs($0.head.midX - glyph.head.midX) < staff.space * 0.3 } ?? glyph
                ghosts.removeAll { abs($0.head.midX - glyph.head.midX) < staff.space * 0.3 }
                ghosts.append(base.translated(by: Point(0, -Double(halfSpaces) * staff.space / 2)))
            }
            v.provisional = ghosts
        }
    }

    /// The graphics linked to `positions` in `path`, per page view.
    private func linked(_ positions: Set<SourcePosition>, path: String) -> [(PageView, [SourcePosition: [Graphic]])] {
        pageViews.compactMap { v in
            guard let page = v.rendered?.page else { return nil }
            var byPosition: [SourcePosition: [Graphic]] = [:]
            for g in page.graphics {
                guard let link = g.link, positions.contains(link.position), PathMatching.same(link.path, path) else { continue }
                byPosition[link.position, default: []].append(g)
            }
            return byPosition.isEmpty ? nil : (v, byPosition)
        }
    }

    /// The last provisional note placed, so several quick insertions chain
    /// to the right of each other before LilyPond answers.
    private var lastInserted: (view: PageView, glyph: NoteGlyph, diatonic: Int)?

    /// Provisional rendering of an insertion: a ghost note after the anchor's
    /// notehead, at the new pitch's staff position.
    func provisionalInsert(after positions: Set<SourcePosition>, path: String, anchorDiatonic: Int?, diatonic: Int) {
        var base: (view: PageView, glyph: NoteGlyph, diatonic: Int)?
        if let anchorDiatonic {
            for (v, byPosition) in linked(positions, path: path) {
                guard let page = v.rendered?.page else { continue }
                for (_, graphics) in byPosition {
                    guard let first = graphics.first,
                          let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY), among: v.staves),
                          let glyph = EngravedPage.noteGlyph(among: graphics, space: staff.space) else { continue }
                    if base == nil || glyph.head.maxX > base!.glyph.head.maxX {
                        base = (v, glyph, anchorDiatonic)
                    }
                }
            }
        }
        if base == nil { base = lastInserted }
        guard let b = base else { return }
        let head = b.glyph.head
        let placed = b.glyph.placingHead(at: Point(
            head.maxX + b.glyph.space * 0.8 + head.width / 2,
            head.midY - Double(diatonic - b.diatonic) * b.glyph.space / 2))
        b.view.provisional.append(placed)
        lastInserted = (b.view, placed, diatonic)
    }

    /// Provisional deletion: take the event's glyphs out of the vector page at
    /// once, rather than crossing them out. The next engraving reflows the
    /// music; until then the rest of the page stays exactly where it was.
    func provisionalDelete(_ positions: Set<SourcePosition>, path: String) {
        for (v, byPosition) in linked(positions, path: path) {
            guard let page = v.rendered?.page else { continue }
            for graphics in byPosition.values {
                guard let first = graphics.first,
                      let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY),
                                             among: v.staves) else {
                    v.removed.formUnion(graphics)
                    continue
                }
                v.removed.formUnion(EngravedPage.removalSet(
                    for: graphics, among: page.graphics, space: staff.space))
            }
        }
    }

    /// Provisional rendering of a duration change: the new value as a badge.
    func provisionalBadge(_ positions: Set<SourcePosition>, path: String, text: String) {
        for (v, byPosition) in linked(positions, path: path) {
            for (_, graphics) in byPosition {
                guard let r = EngravedPage.bounds(of: graphics) else { continue }
                v.badges.removeAll { abs($0.0.midX - r.midX) < 0.3 }
                v.badges.append((r, text))
            }
        }
    }

    /// Drops any mouse entry preview (the armed duration was cleared).
    func clearGhost() {
        pageViews.forEach { $0.ghost = nil }
    }

    fileprivate func pageView(_ v: PageView, selected rect: Rect) {
        let links = v.rendered?.page.linkedGraphics(in: rect, excluding: v.removed).compactMap(\.link) ?? []
        delegate?.canvas(self, didSelect: links)
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.canvas(self, handleKey: event) == true { return }
        super.keyDown(with: event)
    }

    // Re-centre pages when the viewport resizes.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportDidResize(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func viewportDidResize(_ notification: Notification) {
        relayout()
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.canvas(self, didClick: nil, extending: false)
    }
}

private struct Ghost: Equatable {
    var staff: Staff
    var x: Double
    var position: Int
    /// The real engraved notehead (and stem, flags, dot) used as the preview.
    var glyph: NoteGlyph?
}

/// One sheet of paper. Opaque: nothing ever shows through the music.
@MainActor
private final class PageView: NSView {
    weak var owner: ScoreCanvasView?
    var rendered: RenderedPage? {
        didSet {
            staves = rendered?.page.staves ?? []
            ghost = nil
            provisional = []
            removed = []
            highlights = []
            badges = []
            needsDisplay = true
        }
    }
    private(set) var staves: [Staff] = []
    var ghost: Ghost? { didSet { if ghost != oldValue { needsDisplay = true } } }
    /// Engraved note glyphs moved to provisional (not yet engraved) positions.
    var provisional: [NoteGlyph] = [] { didSet { if provisional != oldValue { needsDisplay = true } } }
    /// Glyphs the provisional deletion has taken out of the page.
    var removed: Set<Graphic> = [] { didSet { if removed != oldValue { needsDisplay = true } } }
    var badges: [(Rect, String)] = [] { didSet { needsDisplay = true } }
    var highlights: [Rect] = [] { didSet { if highlights != oldValue { needsDisplay = true } } }
    var lightsOut = false { didSet { needsDisplay = true } }
    private var dragStart: NSPoint?
    private var dragRect: NSRect? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A zoom changes the page's size: redraw at the new size rather than
    /// leaving the layer to stretch (or misplace) the old drawing.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    func crossFade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        layer?.add(fade, forKey: "pondside.recompile")
    }

    private var scale: CGFloat {
        guard let vb = rendered?.page.viewBox, vb.width > 0 else { return 1 }
        return bounds.width / vb.width
    }

    func pagePoint(_ p: NSPoint) -> Point {
        let vb = rendered?.page.viewBox ?? Rect(x: 0, y: 0, width: 1, height: 1)
        return Point(vb.x + p.x / scale, vb.y + p.y / scale)
    }

    func viewRect(for r: Rect) -> NSRect {
        let vb = rendered?.page.viewBox ?? Rect(x: 0, y: 0, width: 1, height: 1)
        return NSRect(x: (r.x - vb.x) * scale, y: (r.y - vb.y) * scale, width: r.width * scale, height: r.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.paper.cgColor)
        ctx.fill(bounds)
        guard let rendered else { return }
        let vb = rendered.page.viewBox
        let s = scale

        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -vb.x, y: -vb.y)
        let visible = Rect(x: vb.x + dirtyRect.minX / s, y: vb.y + dirtyRect.minY / s,
                           width: dirtyRect.width / s, height: dirtyRect.height / s)
        rendered.draw(in: ctx, visible: visible, excluding: removed)
        ctx.restoreGState()

        if lightsOut {
            // Display filter only: dims paper and ink alike, never exported.
            ctx.setFillColor(NSColor.black.withAlphaComponent(Theme.lightsOutDim).cgColor)
            ctx.fill(bounds)
        }

        let accent = Theme.accent
        for r in highlights {
            let rect = viewRect(for: r).insetBy(dx: -3, dy: -3)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(accent.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // Provisional marks use ink, not the accent: the preview is meant to
        // look like the engraving that is about to land, not like a UI ghost.
        let ink = NSColor.black
        if let ghost { drawGhost(ghost, in: ctx, color: ink) }
        if !provisional.isEmpty {
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -vb.x, y: -vb.y)
            for glyph in provisional {
                for graphic in glyph.graphics {
                    RenderedPage.draw(graphic, in: ctx, tint: ink, alpha: 0.55)
                }
                drawLedgers(for: glyph, in: ctx, color: ink)
            }
            ctx.restoreGState()
        }
        for (r, text) in badges {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: Theme.secondarySize, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let label = NSAttributedString(string: text, attributes: attrs)
            let size = label.size()
            let v = viewRect(for: r)
            let badge = NSRect(x: v.midX - size.width / 2 - 4, y: v.minY - size.height - 6, width: size.width + 8, height: size.height + 2)
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            label.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 1))
            NSGraphicsContext.restoreGraphicsState()
        }

        if let dragRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(dragRect)
            ctx.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(dragRect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The note a click would place, with any ledger lines it needs.
    /// A real engraved glyph in the accent colour: the music underneath is
    /// never recoloured.
    private func drawGhost(_ ghost: Ghost, in ctx: CGContext, color: NSColor) {
        let staff = ghost.staff, space = staff.space
        let y = staff.y(ofPosition: ghost.position)

        if let glyph = ghost.glyph, let vb = rendered?.page.viewBox {
            let placed = glyph.placingHead(at: Point(ghost.x, y))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -vb.x, y: -vb.y)
            for graphic in placed.graphics {
                RenderedPage.draw(graphic, in: ctx, tint: color, alpha: 0.55)
            }
            drawLedgers(for: placed, in: ctx, color: color)
            ctx.restoreGState()
            return
        }

        let head = viewRect(for: Rect(x: ghost.x - 0.65 * space, y: y - 0.5 * space, width: 1.3 * space, height: space))
        ctx.setFillColor(color.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: head)
        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(max(1, 0.12 * space * scale))
        var ledgers: [Int] = []
        if ghost.position <= -2 { ledgers = Array(stride(from: -2, through: ghost.position, by: -2)) }
        if ghost.position >= 10 { ledgers = Array(stride(from: 10, through: ghost.position, by: 2)) }
        for p in ledgers {
            let r = viewRect(for: Rect(x: ghost.x - space, y: staff.y(ofPosition: p), width: 2 * space, height: 0))
            ctx.move(to: CGPoint(x: r.minX, y: r.minY))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        ctx.strokePath()
    }

    /// Ledger lines at a provisional glyph's position. The page transform must
    /// already be in effect (page coordinates, y down).
    private func drawLedgers(for glyph: NoteGlyph, in ctx: CGContext, color: NSColor) {
        guard let staff = staves.min(by: {
            abs($0.y(ofPosition: 4) - glyph.head.midY) < abs($1.y(ofPosition: 4) - glyph.head.midY)
        }) else { return }
        let position = staff.position(ofY: glyph.head.midY)
        var ledgers: [Int] = []
        if position <= -2 { ledgers = Array(stride(from: -2, through: position, by: -2)) }
        if position >= 10 { ledgers = Array(stride(from: 10, through: position, by: 2)) }
        guard !ledgers.isEmpty else { return }
        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(max(0.08, 0.12 * staff.space))
        for p in ledgers {
            let y = staff.y(ofPosition: p)
            ctx.move(to: CGPoint(x: glyph.head.midX - staff.space, y: y))
            ctx.addLine(to: CGPoint(x: glyph.head.midX + staff.space, y: y))
        }
        ctx.strokePath()
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.pageView(self, hoverAt: pagePoint(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        owner?.pageView(self, hoverAt: nil)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragRect = nil }
        guard let owner else { return }
        if let r = dragRect, r.width > 4 || r.height > 4 {
            let a = pagePoint(NSPoint(x: r.minX, y: r.minY)), b = pagePoint(NSPoint(x: r.maxX, y: r.maxY))
            owner.pageView(self, selected: Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        } else {
            owner.pageView(self, clickedAt: pagePoint(convert(event.locationInWindow, from: nil)), event: event)
        }
    }
}

/// Compares the file paths LilyPond embeds with ours, through symlinks
/// (macOS's /tmp → /private/tmp is the classic trap).
enum PathMatching {
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ra = URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
        let rb = URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
        return ra == rb
    }
}
