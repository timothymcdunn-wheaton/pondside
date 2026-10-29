struct LensFraction: Sendable, Hashable, Comparable {
    var numerator: Int
    var denominator: Int

    init(_ numerator: Int, _ denominator: Int = 1) {
        let sign = denominator < 0 ? -1 : 1
        let n = numerator * sign
        let d = denominator * sign
        let g = Self.gcd(abs(n), abs(d))
        self.numerator = n / g
        self.denominator = d / g
    }

    static let zero = LensFraction(0)
    static let one = LensFraction(1)

    var isZero: Bool { numerator == 0 }
    var double: Double { Double(numerator) / Double(denominator) }

    static func * (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        LensFraction(lhs.numerator * rhs.numerator, lhs.denominator * rhs.denominator)
    }

    static func + (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        LensFraction(
            lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator,
            lhs.denominator * rhs.denominator
        )
    }

    static func - (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        lhs + LensFraction(-rhs.numerator, rhs.denominator)
    }

    static func < (lhs: LensFraction, rhs: LensFraction) -> Bool {
        lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
    }

    func wholeNoteUnits(divisions: Int) -> Int {
        let units = numerator * divisions * 4
        return max(0, Int((Double(units) / Double(denominator)).rounded()))
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(1, a)
    }
}
