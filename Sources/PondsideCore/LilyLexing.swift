/// Lightweight lexical helpers for LilyPond source.
///
/// These are deliberately shallow: they find the extent of the token that a
/// point-and-click location points at so both views can highlight it. They
/// are not a parser and make no claim about what the token means — LilyPond
/// can redefine its own syntax from Scheme, so meaning comes from the
/// compiler (see docs/DESIGN.md, "static analysis").
public enum LilyLexing {
    /// The extent of the music token starting at `index`.
    ///
    /// - `\command` → the backslash and its name
    /// - `<c e g>4.` → the whole chord with its duration
    /// - `cis''4.~` → pitch, octave marks, accidentals, duration (not the tie)
    /// - `"text"` → the quoted string
    public static func tokenRange(in string: String, at index: String.Index) -> Range<String.Index> {
        let s = string.unicodeScalars
        guard index < s.endIndex else { return index..<index }
        let first = s[index]
        var i = s.index(after: index)

        func advance(while predicate: (Unicode.Scalar) -> Bool) {
            while i < s.endIndex, predicate(s[i]) { i = s.index(after: i) }
        }

        switch first {
        case "\\":
            advance { isIdentifier($0) }
        case "\"":
            var escaped = false
            while i < s.endIndex {
                let c = s[i]
                i = s.index(after: i)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
            }
        case "<":
            if i < s.endIndex, s[i] == "<" { return index..<s.index(after: i) }
            var depth = 1
            while i < s.endIndex, depth > 0 {
                if s[i] == "<" { depth += 1 } else if s[i] == ">" { depth -= 1 }
                if s[i] == "\n", depth > 0 { break }
                i = s.index(after: i)
            }
            advance { isDurationScalar($0) }
        default:
            if isIdentifier(first) || isDurationScalar(first) {
                advance { isIdentifier($0) || isPitchModifier($0) || isDurationScalar($0) }
            }
        }
        return index..<i
    }

    static func isIdentifier(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z": return true
        default: return c.value > 0x7F && c.properties.isAlphabetic
        }
    }

    static func isPitchModifier(_ c: Unicode.Scalar) -> Bool {
        c == "'" || c == "," || c == "!" || c == "?" || c == "="
    }

    static func isDurationScalar(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "0"..."9", ".", "*", "/": return true
        default: return false
        }
    }
}
