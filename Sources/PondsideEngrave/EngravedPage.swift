import Foundation
import PondsideCore

/// An RGBA colour with components in 0...1.
public struct RGBA: Hashable, Sendable, Codable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}

public struct StrokeStyle: Hashable, Sendable {
    public enum Cap: String, Sendable { case butt, round, square }
    public enum Join: String, Sendable { case miter, round, bevel }

    public var width: Double
    public var cap: Cap
    public var join: Join
    public var dash: [Double]

    public init(width: Double, cap: Cap = .butt, join: Join = .miter, dash: [Double] = []) {
        self.width = width
        self.cap = cap
        self.join = join
        self.dash = dash
    }
}

public struct TextRun: Hashable, Sendable {
    public enum Anchor: String, Sendable { case start, middle, end }

    public var string: String
    /// Maps text space (origin at the baseline start, y down) to page space.
    public var transform: AffineTransform
    public var fontFamily: String
    public var fontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var anchor: Anchor
    public var color: RGBA
}

/// One drawable element of an engraved page, in page (viewBox) coordinates.
public struct Graphic: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case path(VectorPath, fill: RGBA?, stroke: RGBA?, style: StrokeStyle)
        case text(TextRun)
    }

    public var content: Content
    /// Approximate bounds in page coordinates, for hit-testing and culling.
    public var bounds: Rect
    /// Source location, when the grob was compiled with point-and-click.
    public var link: PointAndClickLocation?

    public init(content: Content, bounds: Rect, link: PointAndClickLocation? = nil) {
        self.content = content
        self.bounds = bounds
        self.link = link
    }
}

/// A page of engraved music, parsed from LilyPond's SVG output.
///
/// The page model is deliberately renderer-agnostic: the UI draws it with
/// Core Graphics, tests inspect it, and nothing here knows about AppKit.
/// Music is never recoloured — colours are exactly those in the SVG.
public struct EngravedPage: Sendable {
    /// Paper size in millimetres.
    public var widthMM: Double
    public var heightMM: Double
    /// The page's coordinate system (LilyPond uses staff-space-like units).
    public var viewBox: Rect
    public var graphics: [Graphic]
    /// Elements the parser recognised but cannot draw yet (e.g. `<image>`).
    public var unsupportedElements: [String]

    /// Every linked graphic, keyed by source line, sorted by character.
    private var linkIndex: [Int: [(character: Int, graphic: Int)]] = [:]

    public init(widthMM: Double, heightMM: Double, viewBox: Rect, graphics: [Graphic], unsupportedElements: [String] = []) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.viewBox = viewBox
        self.graphics = graphics
        self.unsupportedElements = unsupportedElements
        var index: [Int: [(character: Int, graphic: Int)]] = [:]
        for (i, g) in graphics.enumerated() {
            guard let link = g.link else { continue }
            index[link.line, default: []].append((link.character, i))
        }
        for key in index.keys { index[key]!.sort { $0.character < $1.character } }
        linkIndex = index
    }

    /// The linked graphic under `point` (page coordinates). When several
    /// overlap, the smallest wins, so a notehead beats the slur over it.
    public func hitTest(_ point: Point, tolerance: Double = 0.25,
                        excluding removed: Set<Graphic> = []) -> Graphic? {
        var best: Graphic?
        for g in graphics where g.link != nil && !removed.contains(g) {
            guard g.bounds.insetBy(-tolerance).contains(point) else { continue }
            if best == nil || g.bounds.area < best!.bounds.area { best = g }
        }
        return best
    }

    /// Linked graphics whose bounds intersect `rect`.
    public func linkedGraphics(in rect: Rect, excluding removed: Set<Graphic> = []) -> [Graphic] {
        graphics.filter { $0.link != nil && !removed.contains($0) && $0.bounds.intersects(rect) }
    }

    /// Graphics produced by the token at exactly this source position.
    public func linkedGraphics(at position: SourcePosition, path: String? = nil) -> [Graphic] {
        guard let entries = linkIndex[position.line] else { return [] }
        return entries.filter { $0.character == position.character }
            .map { graphics[$0.graphic] }
            .filter { path == nil || $0.link?.path == path }
    }

    /// The source positions on `line` that produced graphics, ascending.
    public func linkedPositions(onLine line: Int) -> [Int] {
        var out: [Int] = []
        for e in linkIndex[line] ?? [] where out.last != e.character { out.append(e.character) }
        return out
    }

    /// Union of the bounds of the given graphics.
    public static func bounds(of graphics: [Graphic]) -> Rect? {
        guard var r = graphics.first?.bounds else { return nil }
        for g in graphics.dropFirst() { r = r.union(g.bounds) }
        return r
    }
}

// MARK: - SVG parsing

extension EngravedPage {
    public init(svg data: Data) {
        self.init(svgBytes: [UInt8](data))
    }

    public init(svg string: String) {
        self.init(svgBytes: Array(string.utf8))
    }

    init(svgBytes: [UInt8]) {
        var builder = SVGSceneBuilder()
        var tokenizer = XMLTokenizer(svgBytes)
        while let token = tokenizer.next() { builder.consume(token) }
        self.init(widthMM: builder.widthMM, heightMM: builder.heightMM, viewBox: builder.viewBox,
                  graphics: builder.graphics, unsupportedElements: builder.unsupported)
    }
}

/// Inherited presentation state while walking the SVG tree.
private struct SVGState {
    var transform = AffineTransform.identity
    var color = RGBA.black
    var fill: Paint = .color(.black)
    var stroke: Paint = .none
    var strokeWidth = 1.0
    var cap = StrokeStyle.Cap.butt
    var join = StrokeStyle.Join.miter
    var dash: [Double] = []
    var link: PointAndClickLocation?
    var fontFamily = "serif"
    var fontSize = 16.0
    var bold = false
    var italic = false
    var anchor = TextRun.Anchor.start
}

private enum Paint {
    case none
    case currentColor
    case color(RGBA)

    func resolve(_ current: RGBA) -> RGBA? {
        switch self {
        case .none: return nil
        case .currentColor: return current
        case .color(let c): return c
        }
    }
}

private struct SVGSceneBuilder {
    var widthMM = 210.0
    var heightMM = 297.0
    var viewBox = Rect(x: 0, y: 0, width: 210, height: 297)
    var graphics: [Graphic] = []
    var unsupported: [String] = []

    private var stack: [(name: String, state: SVGState)] = []
    private var state = SVGState()
    // Text being collected for the innermost <text> element.
    private var textState: SVGState?
    private var textBuffer = ""
    private var tspanDepth = 0
    private var styleDepth = 0

    mutating func consume(_ token: XMLTokenizer.Token) {
        switch token {
        case let .start(name, attributes, selfClosing):
            start(name, attributes)
            if selfClosing { end(name) }
        case .end(let name):
            end(name)
        case .text(let s):
            guard textState != nil, styleDepth == 0 else { return }
            if tspanDepth > 0 {
                textBuffer += s
            } else {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { textBuffer += trimmed }
            }
        }
    }

    private mutating func start(_ name: String, _ attrs: [String: String]) {
        stack.append((name, state))
        apply(attrs)
        switch name {
        case "svg":
            if stack.count == 1 { readDocument(attrs) }
        case "style":
            styleDepth += 1
        case "a":
            if let href = attrs["xlink:href"] ?? attrs["href"], let link = PointAndClickLocation(uri: href) {
                state.link = link
            }
        case "path":
            if let d = attrs["d"] { emit(VectorPath(svgPathData: d)) }
        case "rect":
            let r = Rect(x: num(attrs["x"]), y: num(attrs["y"]), width: num(attrs["width"]), height: num(attrs["height"]))
            let rx = attrs["rx"].map { num($0) }, ry = attrs["ry"].map { num($0) }
            emit(.rect(r, rx: rx ?? ry ?? 0, ry: ry ?? rx ?? 0))
        case "line":
            emit(VectorPath([.move(Point(num(attrs["x1"]), num(attrs["y1"]))),
                             .line(Point(num(attrs["x2"]), num(attrs["y2"])))]))
        case "circle":
            let r = num(attrs["r"])
            emit(.ellipse(center: Point(num(attrs["cx"]), num(attrs["cy"])), rx: r, ry: r))
        case "ellipse":
            emit(.ellipse(center: Point(num(attrs["cx"]), num(attrs["cy"])), rx: num(attrs["rx"]), ry: num(attrs["ry"])))
        case "polygon", "polyline":
            var scanner = NumberScanner(attrs["points"] ?? "")
            let n = scanner.allNumbers()
            let points = stride(from: 0, to: n.count - 1, by: 2).map { Point(n[$0], n[$0 + 1]) }
            emit(.polyline(points, closed: name == "polygon"))
        case "text":
            textState = state
            textBuffer = ""
        case "tspan":
            tspanDepth += 1
        case "image", "use", "foreignObject":
            unsupported.append(name)
        default:
            break
        }
    }

    private mutating func end(_ name: String) {
        switch name {
        case "style": styleDepth = max(0, styleDepth - 1)
        case "tspan": tspanDepth = max(0, tspanDepth - 1)
        case "text": flushText()
        default: break
        }
        // Pop to the matching element, tolerating malformed nesting.
        while let top = stack.popLast() {
            state = top.state
            if top.name == name { break }
        }
    }

    private mutating func readDocument(_ attrs: [String: String]) {
        if let w = attrs["width"].flatMap(Self.millimetres) { widthMM = w }
        if let h = attrs["height"].flatMap(Self.millimetres) { heightMM = h }
        var scanner = NumberScanner(attrs["viewBox"] ?? "")
        let v = scanner.allNumbers()
        if v.count == 4 {
            viewBox = Rect(x: v[0], y: v[1], width: v[2], height: v[3])
        } else {
            viewBox = Rect(x: 0, y: 0, width: widthMM, height: heightMM)
        }
    }

    private mutating func apply(_ attrs: [String: String]) {
        if let t = attrs["transform"] { state.transform = SVGTransformParsing.parse(t).then(state.transform) }
        if let c = attrs["color"], let rgba = Self.parseColor(c) { state.color = rgba }
        if let f = attrs["fill"] { state.fill = Self.parsePaint(f) }
        if let s = attrs["stroke"] { state.stroke = Self.parsePaint(s) }
        if let w = attrs["stroke-width"], let v = Double(w) { state.strokeWidth = v }
        if let c = attrs["stroke-linecap"], let v = StrokeStyle.Cap(rawValue: c) { state.cap = v }
        if let j = attrs["stroke-linejoin"], let v = StrokeStyle.Join(rawValue: j) { state.join = v }
        if let d = attrs["stroke-dasharray"] {
            var scanner = NumberScanner(d)
            state.dash = d == "none" ? [] : scanner.allNumbers()
        }
        if let f = attrs["font-family"] { state.fontFamily = f }
        if let s = attrs["font-size"], let v = Double(s) { state.fontSize = v }
        if let w = attrs["font-weight"] { state.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
        if let s = attrs["font-style"] { state.italic = s == "italic" || s == "oblique" }
        if let a = attrs["text-anchor"], let v = TextRun.Anchor(rawValue: a) { state.anchor = v }
    }

    private mutating func emit(_ local: VectorPath) {
        let fill = state.fill.resolve(state.color)
        let stroke = state.stroke.resolve(state.color)
        guard fill != nil || stroke != nil else { return }
        let path = local.transformed(by: state.transform)
        let style = StrokeStyle(width: state.strokeWidth * state.transform.scaleFactor, cap: state.cap, join: state.join,
                                dash: state.dash.map { $0 * state.transform.scaleFactor })
        guard var bounds = path.controlBounds else { return }
        if stroke != nil { bounds = bounds.insetBy(-style.width / 2) }
        graphics.append(Graphic(content: .path(path, fill: fill, stroke: stroke, style: style), bounds: bounds, link: state.link))
    }

    private mutating func flushText() {
        guard let ts = textState else { return }
        textState = nil
        let string = textBuffer
        textBuffer = ""
        guard !string.isEmpty, let color = ts.fill.resolve(ts.color) else { return }
        let run = TextRun(string: string, transform: ts.transform, fontFamily: ts.fontFamily, fontSize: ts.fontSize,
                          bold: ts.bold, italic: ts.italic, anchor: ts.anchor, color: color)
        // Estimated extent; good enough to hit-test and cull a text run.
        let width = Double(string.count) * ts.fontSize * 0.55
        let x0: Double
        switch ts.anchor {
        case .start: x0 = 0
        case .middle: x0 = -width / 2
        case .end: x0 = -width
        }
        let corners = [Point(x0, -ts.fontSize * 0.8), Point(x0 + width, -ts.fontSize * 0.8),
                       Point(x0, ts.fontSize * 0.25), Point(x0 + width, ts.fontSize * 0.25)]
        let bounds = Rect(enclosing: corners.map { ts.transform.apply($0) })!
        graphics.append(Graphic(content: .text(run), bounds: bounds, link: ts.link))
    }

    private func num(_ s: String?) -> Double {
        guard let s else { return 0 }
        var scanner = NumberScanner(s)
        return scanner.number() ?? 0
    }

    // MARK: Attribute parsers

    static func millimetres(_ s: String) -> Double? {
        var scanner = NumberScanner(s)
        guard let v = scanner.number() else { return nil }
        if s.hasSuffix("mm") { return v }
        if s.hasSuffix("cm") { return v * 10 }
        if s.hasSuffix("in") { return v * 25.4 }
        if s.hasSuffix("pt") { return v * 25.4 / 72 }
        return v * 25.4 / 96 // px or unitless
    }

    static func parsePaint(_ s: String) -> Paint {
        switch s {
        case "none", "transparent": return .none
        case "currentColor": return .currentColor
        default: return parseColor(s).map(Paint.color) ?? .color(.black)
        }
    }

    static func parseColor(_ s: String) -> RGBA? {
        let s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = Array(s.dropFirst())
            func h(_ i: Int, _ n: Int) -> Double {
                Double(Int(String(hex[i..<(i + n)]), radix: 16) ?? 0) / (n == 1 ? 15 : 255)
            }
            if hex.count == 6 { return RGBA(h(0, 2), h(2, 2), h(4, 2)) }
            if hex.count == 3 { return RGBA(h(0, 1), h(1, 1), h(2, 1)) }
            return nil
        }
        if s.hasPrefix("rgb") {
            // LilyPond writes rgb(100.0000%, 0.0000%, 0.0000%).
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close].split(separator: ",")
            let values: [Double] = parts.map { part in
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasSuffix("%") { return (Double(p.dropLast()) ?? 0) / 100 }
                return (Double(p) ?? 0) / 255
            }
            guard values.count >= 3 else { return nil }
            return RGBA(values[0], values[1], values[2], values.count > 3 ? values[3] : 1)
        }
        switch s {
        case "black": return .black
        case "white": return .white
        case "red": return RGBA(1, 0, 0)
        case "green": return RGBA(0, 0.5, 0)
        case "blue": return RGBA(0, 0, 1)
        case "grey", "gray": return RGBA(0.5, 0.5, 0.5)
        default: return nil
        }
    }
}

/// Parses SVG `transform` attribute lists.
enum SVGTransformParsing {
    static func parse(_ s: String) -> AffineTransform {
        var result = AffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
            var scanner = NumberScanner(String(rest[rest.index(after: open)..<close]))
            let v = scanner.allNumbers()
            var t = AffineTransform.identity
            switch name {
            case "translate" where !v.isEmpty:
                t = .translation(v[0], v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty:
                t = .scale(v[0], v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                t = .rotation(degrees: v[0])
                if v.count >= 3 {
                    t = AffineTransform.translation(-v[1], -v[2]).then(t).then(.translation(v[1], v[2]))
                }
            case "matrix" where v.count == 6:
                t = AffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
            case "skewX" where !v.isEmpty:
                t = AffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, e: 0, f: 0)
            case "skewY" where !v.isEmpty:
                t = AffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, e: 0, f: 0)
            default:
                break
            }
            // "translate(..) scale(..)" applies scale first, then translate.
            result = t.then(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}
