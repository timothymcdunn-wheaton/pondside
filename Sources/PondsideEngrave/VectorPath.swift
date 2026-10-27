import Foundation

/// A resolution-independent path in absolute coordinates.
public struct VectorPath: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case move(Point)
        case line(Point)
        case quad(control: Point, to: Point)
        case cubic(control1: Point, control2: Point, to: Point)
        case close
    }

    public var elements: [Element]

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }

    public func transformed(by t: AffineTransform) -> VectorPath {
        if t.isIdentity { return self }
        return VectorPath(elements.map { element in
            switch element {
            case .move(let p): return .move(t.apply(p))
            case .line(let p): return .line(t.apply(p))
            case .quad(let c, let p): return .quad(control: t.apply(c), to: t.apply(p))
            case .cubic(let c1, let c2, let p): return .cubic(control1: t.apply(c1), control2: t.apply(c2), to: t.apply(p))
            case .close: return .close
            }
        })
    }

    /// Conservative bounds (the hull of all control points).
    public var controlBounds: Rect? {
        var points: [Point] = []
        points.reserveCapacity(elements.count * 3)
        for element in elements {
            switch element {
            case .move(let p), .line(let p): points.append(p)
            case .quad(let c, let p): points.append(c); points.append(p)
            case .cubic(let c1, let c2, let p): points.append(c1); points.append(c2); points.append(p)
            case .close: break
            }
        }
        return Rect(enclosing: points)
    }

    // MARK: - Primitive shapes

    public static func rect(_ r: Rect, rx: Double = 0, ry: Double = 0) -> VectorPath {
        let rx = min(max(rx, 0), r.width / 2), ry = min(max(ry, 0), r.height / 2)
        if rx == 0 || ry == 0 {
            return VectorPath([
                .move(Point(r.minX, r.minY)), .line(Point(r.maxX, r.minY)),
                .line(Point(r.maxX, r.maxY)), .line(Point(r.minX, r.maxY)), .close,
            ])
        }
        let k = 0.5522847498 // cubic approximation of a quarter circle
        let kx = rx * k, ky = ry * k
        return VectorPath([
            .move(Point(r.minX + rx, r.minY)),
            .line(Point(r.maxX - rx, r.minY)),
            .cubic(control1: Point(r.maxX - rx + kx, r.minY), control2: Point(r.maxX, r.minY + ry - ky), to: Point(r.maxX, r.minY + ry)),
            .line(Point(r.maxX, r.maxY - ry)),
            .cubic(control1: Point(r.maxX, r.maxY - ry + ky), control2: Point(r.maxX - rx + kx, r.maxY), to: Point(r.maxX - rx, r.maxY)),
            .line(Point(r.minX + rx, r.maxY)),
            .cubic(control1: Point(r.minX + rx - kx, r.maxY), control2: Point(r.minX, r.maxY - ry + ky), to: Point(r.minX, r.maxY - ry)),
            .line(Point(r.minX, r.minY + ry)),
            .cubic(control1: Point(r.minX, r.minY + ry - ky), control2: Point(r.minX + rx - kx, r.minY), to: Point(r.minX + rx, r.minY)),
            .close,
        ])
    }

    public static func ellipse(center c: Point, rx: Double, ry: Double) -> VectorPath {
        let k = 0.5522847498
        let kx = rx * k, ky = ry * k
        return VectorPath([
            .move(Point(c.x + rx, c.y)),
            .cubic(control1: Point(c.x + rx, c.y + ky), control2: Point(c.x + kx, c.y + ry), to: Point(c.x, c.y + ry)),
            .cubic(control1: Point(c.x - kx, c.y + ry), control2: Point(c.x - rx, c.y + ky), to: Point(c.x - rx, c.y)),
            .cubic(control1: Point(c.x - rx, c.y - ky), control2: Point(c.x - kx, c.y - ry), to: Point(c.x, c.y - ry)),
            .cubic(control1: Point(c.x + kx, c.y - ry), control2: Point(c.x + rx, c.y - ky), to: Point(c.x + rx, c.y)),
            .close,
        ])
    }

    public static func polyline(_ points: [Point], closed: Bool) -> VectorPath {
        guard let first = points.first else { return VectorPath() }
        var elements: [Element] = [.move(first)]
        elements += points.dropFirst().map { .line($0) }
        if closed { elements.append(.close) }
        return VectorPath(elements)
    }
}

// MARK: - SVG path data

extension VectorPath {
    /// Parses SVG path data (`d` attribute): all commands, absolute and
    /// relative, including smooth curves and elliptical arcs.
    public init(svgPathData d: String) {
        var scanner = NumberScanner(d)
        var elements: [Element] = []
        var current = Point.zero
        var subpathStart = Point.zero
        var lastCubicControl: Point?
        var lastQuadControl: Point?
        var command: UInt8 = 0

        while true {
            if let c = scanner.nextCommand() {
                command = c
            } else if command == 0 || !scanner.hasNumber() {
                break
            }
            // An implicit repeat of `M` is a line-to.
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command
            func pt(_ x: Double, _ y: Double) -> Point {
                relative ? Point(current.x + x, current.y + y) : Point(x, y)
            }
            var cubicControl: Point?
            var quadControl: Point?

            switch upper {
            case UInt8(ascii: "M"):
                guard let x = scanner.number(), let y = scanner.number() else { break }
                current = pt(x, y)
                subpathStart = current
                elements.append(.move(current))
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let x = scanner.number(), let y = scanner.number() else { break }
                current = pt(x, y)
                elements.append(.line(current))
            case UInt8(ascii: "H"):
                guard let x = scanner.number() else { break }
                current = Point(relative ? current.x + x : x, current.y)
                elements.append(.line(current))
            case UInt8(ascii: "V"):
                guard let y = scanner.number() else { break }
                current = Point(current.x, relative ? current.y + y : y)
                elements.append(.line(current))
            case UInt8(ascii: "C"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), p = pt(x, y)
                elements.append(.cubic(control1: c1, control2: c2, to: p))
                cubicControl = c2
                current = p
            case UInt8(ascii: "S"):
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c1 = lastCubicControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2), p = pt(x, y)
                elements.append(.cubic(control1: c1, control2: c2, to: p))
                cubicControl = c2
                current = p
            case UInt8(ascii: "Q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c = pt(x1, y1), p = pt(x, y)
                elements.append(.quad(control: c, to: p))
                quadControl = c
                current = p
            case UInt8(ascii: "T"):
                guard let x = scanner.number(), let y = scanner.number() else { break }
                let c = lastQuadControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let p = pt(x, y)
                elements.append(.quad(control: c, to: p))
                quadControl = c
                current = p
            case UInt8(ascii: "A"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let p = pt(x, y)
                elements += Self.arc(from: current, to: p, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = p
            case UInt8(ascii: "Z"):
                elements.append(.close)
                current = subpathStart
                command = 0
            default:
                command = 0
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
            if scanner.isStuck { break }
        }
        self.init(elements)
    }

    /// Converts an SVG endpoint-parameterised arc to cubic Béziers
    /// (SVG 1.1 implementation notes, appendix F.6).
    static func arc(from p0: Point, to p1: Point, rx radiusX: Double, ry radiusY: Double, rotation: Double,
                    largeArc: Bool, sweep: Bool) -> [Element] {
        var rx = abs(radiusX), ry = abs(radiusY)
        if p0 == p1 { return [] }
        if rx == 0 || ry == 0 { return [.line(p1)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func onEllipse(_ theta: Double) -> Point {
            Point(cx + rx * cos(theta) * cosPhi - ry * sin(theta) * sinPhi,
                  cy + rx * cos(theta) * sinPhi + ry * sin(theta) * cosPhi)
        }
        func derivative(_ theta: Double) -> Point {
            Point(-rx * sin(theta) * cosPhi - ry * cos(theta) * sinPhi,
                  -rx * sin(theta) * sinPhi + ry * cos(theta) * cosPhi)
        }
        var result: [Element] = []
        var theta = theta1
        for k in 0..<segments {
            let next = theta + step
            let a = onEllipse(theta), b = k == segments - 1 ? p1 : onEllipse(next)
            let da = derivative(theta), db = derivative(next)
            result.append(.cubic(control1: Point(a.x + t * da.x, a.y + t * da.y),
                                 control2: Point(b.x - t * db.x, b.y - t * db.y),
                                 to: b))
            theta = next
        }
        return result
    }
}

/// Scans numbers and commands from SVG path data and similar attributes.
struct NumberScanner {
    private let bytes: [UInt8]
    private var i = 0
    private var lastPosition = -1
    private(set) var isStuck = false

    init(_ s: String) {
        bytes = Array(s.utf8)
    }

    private mutating func skipSeparators() {
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == UInt8(ascii: ",") { i += 1 } else { break }
        }
    }

    mutating func nextCommand() -> UInt8? {
        // Detect lack of progress so malformed input can never loop forever.
        isStuck = i == lastPosition
        lastPosition = i
        skipSeparators()
        guard i < bytes.count else { return nil }
        let b = bytes[i]
        let isLetter = (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
        if isLetter, b != UInt8(ascii: "e"), b != UInt8(ascii: "E") {
            i += 1
            return b
        }
        return nil
    }

    mutating func hasNumber() -> Bool {
        skipSeparators()
        guard i < bytes.count else { return false }
        let b = bytes[i]
        return (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-") || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
    }

    /// Arc flags may be written without separators ("a1 1 0 011 1").
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case UInt8(ascii: "0"): i += 1; return false
        case UInt8(ascii: "1"): i += 1; return true
        default: return nil
        }
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
        var sawDigit = false, sawDot = false
        while i < bytes.count {
            let b = bytes[i]
            if b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") {
                sawDigit = true
            } else if b == UInt8(ascii: "."), !sawDot {
                sawDot = true
            } else {
                break
            }
            i += 1
        }
        if sawDigit, i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
            if j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") {
                i = j
                while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
            }
        }
        guard sawDigit else {
            i = start
            return nil
        }
        return Double(String(decoding: bytes[start..<i], as: UTF8.self))
    }

    /// All numbers in the input, for `points` and `viewBox` attributes.
    mutating func allNumbers() -> [Double] {
        var out: [Double] = []
        while let n = number() { out.append(n) }
        return out
    }
}
