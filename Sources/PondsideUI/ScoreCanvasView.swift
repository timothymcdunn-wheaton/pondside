import AppKit
import PondsideCore
import PondsideEngrave

@MainActor
protocol ScoreCanvasDelegate: AnyObject {
    /// The user clicked a linked glyph (or empty paper: nil).
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool)
    /// The user dragged a selection rectangle over these links.
    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation])
    /// Keyboard navigation through linked objects in source order.
    func canvas(_ canvas: ScoreCanvasView, moveSelectionBy step: Int)
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    /// Replaces the pages, cross-fading so a recompile never flickers.
    func setPages(_ newPages: [EngravedPage]) {
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
        let link = v.rendered?.page.hitTest(p, tolerance: 0.3 / max(zoom, 0.5))?.link
        delegate?.canvas(self, didClick: link, extending: event.modifierFlags.contains(.shift))
    }

    fileprivate func pageView(_ v: PageView, selected rect: Rect) {
        let links = v.rendered?.page.linkedGraphics(in: rect).compactMap(\.link) ?? []
        delegate?.canvas(self, didSelect: links)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            delegate?.canvas(self, didClick: nil, extending: false)
            return
        }
        switch event.specialKey {
        case .rightArrow?: delegate?.canvas(self, moveSelectionBy: 1)
        case .leftArrow?: delegate?.canvas(self, moveSelectionBy: -1)
        default: super.keyDown(with: event)
        }
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

/// One sheet of paper. Opaque: nothing ever shows through the music.
@MainActor
private final class PageView: NSView {
    weak var owner: ScoreCanvasView?
    var rendered: RenderedPage? { didSet { needsDisplay = true } }
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
        rendered.draw(in: ctx, visible: visible)
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

        if let dragRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(dragRect)
            ctx.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(dragRect.insetBy(dx: 0.5, dy: 0.5))
        }
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
