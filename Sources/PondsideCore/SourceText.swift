/// A position in source text, in the coordinates LilyPond itself reports.
///
/// `line` is 1-based. `character` is a 0-based offset counted in Unicode
/// scalars from the start of the line — the unit LilyPond uses for the
/// `char` field of point-and-click URIs.
public struct SourcePosition: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
        (lhs.line, lhs.character) < (rhs.line, rhs.character)
    }

    public var description: String { "\(line):\(character)" }
}

/// An immutable snapshot of a document's text with a line index.
///
/// All conversions between LilyPond's coordinates (line / scalar offset /
/// tab-expanded display column) and `String.Index` go through here, so the
/// rest of the system never does ad-hoc counting.
public struct SourceText: Sendable, Equatable {
    public let string: String
    /// Index of the first Unicode scalar of each line. Always non-empty.
    private let lineStarts: [String.Index]

    /// LilyPond expands tabs to multiples of 8 when computing columns.
    public static let lilyPondTabWidth = 8

    public init(_ string: String) {
        self.string = string
        let scalars = string.unicodeScalars
        var starts = [scalars.startIndex]
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let next = scalars.index(after: i)
            if scalars[i] == "\n" { starts.append(next) }
            i = next
        }
        lineStarts = starts
    }

    public static func == (lhs: SourceText, rhs: SourceText) -> Bool {
        lhs.string == rhs.string
    }

    public var lineCount: Int { lineStarts.count }

    /// The range of a 1-based line, excluding its terminating newline.
    public func lineRange(_ line: Int) -> Range<String.Index>? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let start = lineStarts[line - 1]
        let end: String.Index
        if line < lineStarts.count {
            end = string.unicodeScalars.index(before: lineStarts[line])
        } else {
            end = string.unicodeScalars.endIndex
        }
        return start..<end
    }

    /// The text of a 1-based line, excluding its newline.
    public func lineText(_ line: Int) -> Substring? {
        lineRange(line).map { string[$0] }
    }

    /// Converts a LilyPond (line, scalar offset) position to an index.
    /// An offset equal to the line length addresses the end of the line.
    public func index(of position: SourcePosition) -> String.Index? {
        guard let range = lineRange(position.line), position.character >= 0 else { return nil }
        let scalars = string.unicodeScalars
        var i = range.lowerBound
        var n = 0
        while n < position.character {
            guard i < range.upperBound else { return nil }
            i = scalars.index(after: i)
            n += 1
        }
        return i
    }

    /// Converts a 1-based, tab-expanded display column (as printed in
    /// LilyPond diagnostics) to a position on the same line.
    public func position(line: Int, displayColumn: Int, tabWidth: Int = SourceText.lilyPondTabWidth) -> SourcePosition? {
        guard let range = lineRange(line), displayColumn >= 1 else { return nil }
        let target = displayColumn - 1
        var column = 0
        var character = 0
        for scalar in string.unicodeScalars[range] {
            if column >= target { break }
            column = scalar == "\t" ? (column / tabWidth + 1) * tabWidth : column + 1
            character += 1
        }
        return SourcePosition(line: line, character: character)
    }

    /// The LilyPond position of an index into `string`.
    public func position(of index: String.Index) -> SourcePosition {
        // Binary search for the last line start <= index.
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        let character = string.unicodeScalars.distance(from: lineStarts[lo], to: index)
        return SourcePosition(line: lo + 1, character: character)
    }

    /// UTF-16 offset of an index, for bridging to text views that use NSRange.
    public func utf16Offset(of index: String.Index) -> Int {
        string.utf16.distance(from: string.utf16.startIndex, to: index)
    }

    /// Index for a UTF-16 offset, clamped to the string.
    public func index(utf16Offset offset: Int) -> String.Index {
        let utf16 = string.utf16
        let clamped = max(0, min(offset, utf16.count))
        return utf16.index(utf16.startIndex, offsetBy: clamped)
    }
}
