import AppKit
import CoreText
import PondsideCore
import PondsideEngrave

/// A page prepared for drawing: Core Graphics paths and Core Text lines are
/// built once per compile, not once per frame.
@MainActor
final class RenderedPage {
    let page: EngravedPage
    private let items: [Item]

    private enum Item {
        case path(CGPath, fill: CGColor?, stroke: CGColor?, StrokeStyle)
        case text(CTLine, transform: CGAffineTransform, xOffset: CGFloat)
    }

    init(_ page: EngravedPage) {
        self.page = page
        items = page.graphics.map { graphic in
            switch graphic.content {
            case let .path(path, fill, stroke, style):
                return .path(Self.cgPath(path), fill: fill.map { Self.cgColor($0) }, stroke: stroke.map { Self.cgColor($0) }, style)
            case let .text(run):
                let font = FontResolver.font(family: run.fontFamily, size: run.fontSize, bold: run.bold, italic: run.italic)
                let attributed = NSAttributedString(string: run.string, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(cgColor: Self.cgColor(run.color)) ?? NSColor.black,
                ])
                let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x: CGFloat
                switch run.anchor {
                case .start: x = 0
                case .middle: x = -width / 2
                case .end: x = -width
                }
                let t = run.transform
                return .text(line, transform: CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.e, ty: t.f), xOffset: x)
            }
        }
    }

    /// Draws the music. The context must already map page (viewBox) units
    /// to the destination, y pointing down.
    func draw(in ctx: CGContext, visible: Rect?) {
        for (i, item) in items.enumerated() {
            if let visible, !page.graphics[i].bounds.intersects(visible) { continue }
            switch item {
            case let .path(path, fill, stroke, style):
                if let fill {
                    ctx.addPath(path)
                    ctx.setFillColor(fill)
                    ctx.fillPath()
                }
                if let stroke {
                    ctx.addPath(path)
                    ctx.setStrokeColor(stroke)
                    ctx.setLineWidth(style.width)
                    ctx.setLineCap(Self.cap(style.cap))
                    ctx.setLineJoin(Self.join(style.join))
                    ctx.setLineDash(phase: 0, lengths: style.dash.map { CGFloat($0) })
                    ctx.strokePath()
                }
            case let .text(line, transform, xOffset):
                ctx.saveGState()
                ctx.concatenate(transform)
                // Core Text draws y-up; flip glyphs for the y-down page.
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: xOffset, y: 0)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: Conversions

    static func cgPath(_ path: VectorPath) -> CGPath {
        let p = CGMutablePath()
        var hasCurrentPoint = false
        for element in path.elements {
            switch element {
            case .move(let a):
                p.move(to: CGPoint(x: a.x, y: a.y))
                hasCurrentPoint = true
            case .line(let a):
                if hasCurrentPoint { p.addLine(to: CGPoint(x: a.x, y: a.y)) } else { p.move(to: CGPoint(x: a.x, y: a.y)) }
                hasCurrentPoint = true
            case let .quad(c, a):
                if !hasCurrentPoint { p.move(to: CGPoint(x: c.x, y: c.y)) }
                p.addQuadCurve(to: CGPoint(x: a.x, y: a.y), control: CGPoint(x: c.x, y: c.y))
                hasCurrentPoint = true
            case let .cubic(c1, c2, a):
                if !hasCurrentPoint { p.move(to: CGPoint(x: c1.x, y: c1.y)) }
                p.addCurve(to: CGPoint(x: a.x, y: a.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
                hasCurrentPoint = true
            case .close:
                if hasCurrentPoint { p.closeSubpath() }
            }
        }
        return p
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func cap(_ c: StrokeStyle.Cap) -> CGLineCap {
        switch c {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }

    static func join(_ j: StrokeStyle.Join) -> CGLineJoin {
        switch j {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

/// Maps the font families LilyPond names in SVG to installed fonts.
///
/// LilyPond's default text fonts are C059 / Nimbus (URW). If the user has
/// them, the canvas matches the PDF exactly; otherwise the closest metric
/// relatives are used. Music glyphs are paths and are always exact.
@MainActor
enum FontResolver {
    private static var cache: [String: NSFont] = [:]

    static let families: [String: [String]] = [
        "serif": ["C059", "TeX Gyre Schola", "Century Schoolbook", "New Century Schoolbook", "Times New Roman", "Times"],
        "sans-serif": ["Nimbus Sans", "TeX Gyre Heros", "Helvetica Neue", "Helvetica"],
        "monospace": ["Nimbus Mono PS", "TeX Gyre Cursor", "Courier New", "Menlo"],
    ]

    static func font(family: String, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let key = "\(family)|\(size)|\(bold)|\(italic)"
        if let f = cache[key] { return f }
        let candidates = families[family] ?? ([family] + families["serif"]!)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        var result: NSFont?
        for name in candidates {
            if let f = NSFontManager.shared.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: CGFloat(size)) {
                result = f
                break
            }
        }
        let font = result ?? NSFont.systemFont(ofSize: CGFloat(size))
        cache[key] = font
        return font
    }
}
