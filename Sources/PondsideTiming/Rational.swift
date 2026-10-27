/// An exact fraction: LilyPond moments are rationals in whole notes, and
/// timing must not accumulate floating-point drift before the last step.
public struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator != 0, "zero denominator")
        let g = Self.gcd(abs(numerator), abs(denominator))
        let sign = denominator < 0 ? -1 : 1
        self.numerator = sign * numerator / max(g, 1)
        self.denominator = sign * denominator / max(g, 1)
    }

    /// "217/4", "3", "-1/8" (Scheme's `number->string` of a rational).
    public init?(parsing text: some StringProtocol) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let n = Int(parts[0]) else { return nil }
        let d = parts.count == 2 ? Int(parts[1]) : 1
        guard let d, d != 0 else { return nil }
        self.init(n, d)
    }

    public static let zero = Rational(0)

    public var doubleValue: Double { Double(numerator) / Double(denominator) }

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    public static func + (a: Rational, b: Rational) -> Rational {
        Rational(a.numerator * b.denominator + b.numerator * a.denominator, a.denominator * b.denominator)
    }

    public static func - (a: Rational, b: Rational) -> Rational {
        Rational(a.numerator * b.denominator - b.numerator * a.denominator, a.denominator * b.denominator)
    }

    public static func * (a: Rational, b: Rational) -> Rational {
        Rational(a.numerator * b.numerator, a.denominator * b.denominator)
    }

    public static func / (a: Rational, b: Rational) -> Rational {
        Rational(a.numerator * b.denominator, a.denominator * b.numerator)
    }

    public static func < (a: Rational, b: Rational) -> Bool {
        a.numerator * b.denominator < b.numerator * a.denominator
    }
}
