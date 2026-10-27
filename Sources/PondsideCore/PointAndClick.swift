/// A source location embedded by LilyPond's point-and-click mode.
///
/// LilyPond writes links of the form
/// `textedit:///abs/path/score.ly:LINE:CHAR:COLUMN`, where `LINE` is 1-based,
/// `CHAR` is a 0-based Unicode-scalar offset into the line, and `COLUMN` is a
/// 1-based display column with tabs expanded to multiples of 8. The path may
/// itself contain colons, so the numeric fields are parsed from the right.
public struct PointAndClickLocation: Hashable, Sendable, CustomStringConvertible {
    public var path: String
    public var line: Int
    public var character: Int
    public var column: Int

    public init(path: String, line: Int, character: Int, column: Int) {
        self.path = path
        self.line = line
        self.character = character
        self.column = column
    }

    public static let scheme = "textedit://"

    public init?(uri: String) {
        guard uri.hasPrefix(Self.scheme) else { return nil }
        let body = uri.dropFirst(Self.scheme.count)
        var fields: [Int] = []
        var rest = Substring(body)
        for _ in 0..<3 {
            guard let colon = rest.lastIndex(of: ":"),
                  let value = Int(rest[rest.index(after: colon)...]) else { return nil }
            fields.append(value)
            rest = rest[..<colon]
        }
        guard !rest.isEmpty else { return nil }
        self.path = PercentEncoding.decode(String(rest))
        self.column = fields[0]
        self.character = fields[1]
        self.line = fields[2]
    }

    public var position: SourcePosition { SourcePosition(line: line, character: character) }

    public var uri: String {
        "\(Self.scheme)\(PercentEncoding.encodePath(path)):\(line):\(character):\(column)"
    }

    public var description: String { "\(path):\(line):\(character)" }
}

/// Minimal percent-encoding for file paths in textedit URIs.
public enum PercentEncoding {
    public static func decode(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        var it = Array(s.utf8)[...]
        while let b = it.popFirst() {
            if b == UInt8(ascii: "%"), it.count >= 2,
               let hi = hexValue(it[it.startIndex]),
               let lo = hexValue(it[it.index(after: it.startIndex)]) {
                bytes.append(hi << 4 | lo)
                it = it.dropFirst(2)
            } else {
                bytes.append(b)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func encodePath(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "/"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                let hex = Array("0123456789ABCDEF".unicodeScalars)
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(hex[Int(b >> 4)])
                out.unicodeScalars.append(hex[Int(b & 0xF)])
            }
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
