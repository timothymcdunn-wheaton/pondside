/// A LilyPond release version, e.g. 2.26.0.
public struct LilyPondVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "2.26.0", "2.26", or a string beginning with a version.
    public init?(_ string: some StringProtocol) {
        var numbers: [Int] = []
        var current = ""
        for c in string {
            if c.isASCII, c.isNumber {
                current.append(c)
            } else if c == ".", !current.isEmpty {
                numbers.append(Int(current)!)
                current = ""
            } else {
                break
            }
        }
        if !current.isEmpty { numbers.append(Int(current)!) }
        guard numbers.count >= 2 else { return nil }
        self.init(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
    }

    /// LilyPond's convention: odd minor numbers are development releases.
    public var isStable: Bool { minor % 2 == 0 }

    public static func < (lhs: LilyPondVersion, rhs: LilyPondVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// The version a score pins via its `\version "x.y.z"` statement.
    /// Only the first statement counts, and comments are skipped.
    public static func declared(in source: String) -> LilyPondVersion? {
        var rest = Substring(source)
        while let r = rest.firstRange(of: "\\version") {
            let lineStart = rest[..<r.lowerBound].lastIndex(of: "\n").map { rest.index(after: $0) } ?? rest.startIndex
            let beforeOnLine = rest[lineStart..<r.lowerBound]
            rest = rest[r.upperBound...]
            if beforeOnLine.contains("%") { continue }
            let afterKeyword = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard afterKeyword.first == "\"" else { continue }
            return LilyPondVersion(afterKeyword.dropFirst())
        }
        return nil
    }
}
