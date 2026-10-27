/// A replacement of a UTF-8 byte range. Score edits are lists of these.
public struct TextEdit: Hashable, Sendable, CustomStringConvertible {
    public var range: Range<Int>
    public var replacement: String

    public init(_ range: Range<Int>, _ replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public static func insert(_ text: String, at offset: Int) -> TextEdit {
        TextEdit(offset..<offset, text)
    }

    public var delta: Int { replacement.utf8.count - range.count }

    public var description: String { "\(range.lowerBound)..<\(range.upperBound) → \"\(replacement)\"" }
}

extension Array where Element == TextEdit {
    /// The edits sorted by position. They must not overlap.
    public var normalized: [TextEdit] {
        sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
    }

    public var isNonOverlapping: Bool {
        let n = normalized
        for (a, b) in zip(n, n.dropFirst()) where a.range.upperBound > b.range.lowerBound { return false }
        return true
    }

    /// Applies the edits to UTF-8 bytes.
    public func apply(to bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 64)
        var cursor = 0
        for e in normalized {
            out.append(contentsOf: bytes[cursor..<e.range.lowerBound])
            out.append(contentsOf: Array(e.replacement.utf8))
            cursor = e.range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return out
    }

    public func apply(to text: String) -> String {
        String(decoding: apply(to: Array(text.utf8)), as: UTF8.self)
    }

    /// Maps an offset in the old text to the new text. An offset at the
    /// start of an insertion stays before it.
    public func mapOffset(_ offset: Int) -> Int {
        var shift = 0
        for e in normalized {
            if offset <= e.range.lowerBound { break }
            if offset < e.range.upperBound { return e.range.lowerBound + shift }
            shift += e.delta
        }
        return offset + shift
    }

    /// The edits that undo these, expressed against the *new* text.
    public func inverse(original bytes: [UInt8]) -> [TextEdit] {
        var shift = 0
        var out: [TextEdit] = []
        for e in normalized {
            let start = e.range.lowerBound + shift
            let newRange = start..<(start + e.replacement.utf8.count)
            out.append(TextEdit(newRange, String(decoding: bytes[e.range], as: UTF8.self)))
            shift += e.delta
        }
        return out
    }
}

/// UTF-8 ↔ UTF-16 offset conversion, for text views that speak NSRange.
public enum OffsetConversion {
    public static func utf16(fromUTF8 offset: Int, in text: String) -> Int {
        let u8 = text.utf8
        let i = u8.index(u8.startIndex, offsetBy: max(0, min(offset, u8.count)))
        return text.utf16.distance(from: text.utf16.startIndex, to: i)
    }

    public static func utf8(fromUTF16 offset: Int, in text: String) -> Int {
        let u16 = text.utf16
        let i = u16.index(u16.startIndex, offsetBy: max(0, min(offset, u16.count)))
        return text.utf8.distance(from: text.utf8.startIndex, to: i)
    }
}
