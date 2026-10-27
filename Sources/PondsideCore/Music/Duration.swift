/// A written LilyPond duration: `4.`, `8*2/3`, `\breve`, `1*3/4`.
///
/// Equality is by value, not spelling. `text` reproduces LilyPond syntax.
public struct DurationValue: Hashable, Sendable, CustomStringConvertible {
    /// log2 of the denominator: 0 = whole, 2 = quarter, -1 = breve.
    public var log: Int
    public var dots: Int
    public var factorNumerator: Int
    public var factorDenominator: Int

    public init(log: Int, dots: Int = 0, factorNumerator: Int = 1, factorDenominator: Int = 1) {
        self.log = log
        self.dots = dots
        let g = Self.gcd(max(1, factorNumerator), max(1, factorDenominator))
        self.factorNumerator = max(1, factorNumerator) / g
        self.factorDenominator = max(1, factorDenominator) / g
    }

    /// LilyPond's initial default duration.
    public static let quarter = DurationValue(log: 2)

    /// The duration for a number key: 1, 2, 4, 8, 16, 32, 64, 128.
    public init?(denominator: Int) {
        guard denominator > 0, denominator & (denominator - 1) == 0, denominator <= 128 else { return nil }
        self.init(log: denominator.trailingZeroBitCount)
    }

    public var text: String {
        var s: String
        switch log {
        case -1: s = "\\breve"
        case -2: s = "\\longa"
        case -3: s = "\\maxima"
        default: s = String(1 << log)
        }
        s += String(repeating: ".", count: dots)
        if factorNumerator != 1 || factorDenominator != 1 {
            s += "*\(factorNumerator)"
            if factorDenominator != 1 { s += "/\(factorDenominator)" }
        }
        return s
    }

    public var description: String { text }

    /// Length in whole notes as an exact fraction (numerator, denominator).
    public var wholeNotes: (Int, Int) {
        // base = 2^-log; dots: base * (2 - 2^-dots)
        var num = 1, den = 1
        if log >= 0 { den = 1 << log } else { num = 1 << -log }
        // Apply dots: multiply by (2^(dots+1) - 1) / 2^dots
        num *= (1 << (dots + 1)) - 1
        den *= 1 << dots
        num *= factorNumerator
        den *= factorDenominator
        let g = Self.gcd(num, den)
        return (num / g, den / g)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    /// Parses the text of a duration node.
    public init?(text: String) {
        var rest = Substring(text)
        var log: Int
        if rest.hasPrefix("\\breve") { log = -1; rest = rest.dropFirst(6) }
        else if rest.hasPrefix("\\longa") { log = -2; rest = rest.dropFirst(6) }
        else if rest.hasPrefix("\\maxima") { log = -3; rest = rest.dropFirst(7) }
        else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard let n = Int(digits), n > 0, n & (n - 1) == 0 else { return nil }
            log = n.trailingZeroBitCount
            rest = rest.dropFirst(digits.count)
        }
        var dots = 0
        while rest.first == "." { dots += 1; rest = rest.dropFirst() }
        var num = 1, den = 1
        while rest.first == "*" {
            rest = rest.dropFirst()
            let a = rest.prefix { $0.isASCII && $0.isNumber }
            rest = rest.dropFirst(a.count)
            var b: Substring = "1"
            if rest.first == "/" {
                rest = rest.dropFirst()
                b = rest.prefix { $0.isASCII && $0.isNumber }
                rest = rest.dropFirst(b.count)
            }
            // Bounded so absurd multipliers can't overflow.
            num = min(num * min(Int(a.prefix(6)) ?? 1, 1_000_000), 1_000_000_000)
            den = min(den * min(Int(b.prefix(6)) ?? 1, 1_000_000), 1_000_000_000)
        }
        self.init(log: log, dots: dots, factorNumerator: num, factorDenominator: den)
    }
}
