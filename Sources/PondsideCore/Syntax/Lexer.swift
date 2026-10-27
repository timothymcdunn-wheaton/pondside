/// Lexer modes. LilyPond tokenizes differently inside `\lyricmode`,
/// `\chordmode`, `\markup` and friends; the parser tells the lexer which.
public enum LexMode: UInt8, Sendable {
    case notes, initial, lyrics, chords, figures, drums, markup
}

struct Token {
    var kind: SyntaxKind
    var start: Int
    var end: Int
}

/// Byte-level tokenizer. Every byte belongs to exactly one token.
struct Lexer {
    let b: [UInt8]

    init(_ bytes: [UInt8]) {
        b = bytes
    }

    static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B
    }

    static func isLetter(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }

    /// Characters that form an articulation shorthand after - ^ _.
    static let shorthand: Set<UInt8> = [UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: ">"), UInt8(ascii: "^"),
                                        UInt8(ascii: "+"), UInt8(ascii: "!"), UInt8(ascii: "_")]

    /// A LilyPond identifier: letters, with single `-` or `_` between letters.
    func identifierEnd(from start: Int) -> Int {
        var i = start
        while i < b.count {
            if Lexer.isLetter(b[i]) { i += 1; continue }
            if (b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "_")), Lexer.isLetter(at(i + 1)) { i += 2; continue }
            break
        }
        return i
    }

    func stringEnd(from start: Int) -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return b.count
    }

    /// Skips one UTF-8 encoded scalar.
    func scalarEnd(from i: Int) -> Int {
        var j = i + 1
        while j < b.count, b[j] & 0xC0 == 0x80 { j += 1 }
        return j
    }

    func token(at p: Int, mode: LexMode) -> Token {
        let c = b[p]
        func tok(_ k: SyntaxKind, _ len: Int) -> Token { Token(kind: k, start: p, end: min(b.count, p + len)) }

        if Lexer.isSpace(c) {
            var i = p + 1
            while i < b.count, Lexer.isSpace(b[i]) { i += 1 }
            return Token(kind: .whitespace, start: p, end: i)
        }
        if c == UInt8(ascii: "%") {
            if at(p + 1) == UInt8(ascii: "{") {
                var i = p + 2
                while i < b.count, !(b[i] == UInt8(ascii: "%") && at(i + 1) == UInt8(ascii: "}")) { i += 1 }
                return Token(kind: .blockComment, start: p, end: min(b.count, i + 2))
            }
            var i = p + 1
            while i < b.count, b[i] != 0x0A { i += 1 }
            return Token(kind: .lineComment, start: p, end: i)
        }
        if c == UInt8(ascii: "\"") { return Token(kind: .string, start: p, end: stringEnd(from: p)) }
        if c == UInt8(ascii: "#") {
            if at(p + 1) == UInt8(ascii: "}") { return tok(.embeddedClose, 2) }
            return tok(.hash, 1)
        }
        if c == UInt8(ascii: "$") { return tok(.hash, 1) }
        if c == UInt8(ascii: "\\") {
            if Lexer.isLetter(at(p + 1)) { return Token(kind: .command, start: p, end: identifierEnd(from: p + 1)) }
            if p + 1 < b.count, !Lexer.isSpace(b[p + 1]) { return Token(kind: .escapedPunct, start: p, end: scalarEnd(from: p + 1)) }
            return tok(.unknown, 1)
        }

        switch mode {
        case .markup:
            if c == UInt8(ascii: "{") { return tok(.openBrace, 1) }
            if c == UInt8(ascii: "}") { return tok(.closeBrace, 1) }
            var i = p
            while i < b.count {
                let d = b[i]
                if Lexer.isSpace(d) || d == UInt8(ascii: "{") || d == UInt8(ascii: "}") || d == UInt8(ascii: "\"")
                    || d == UInt8(ascii: "\\") || d == UInt8(ascii: "#") || d == UInt8(ascii: "$") || d == UInt8(ascii: "%") { break }
                i += 1
            }
            return Token(kind: .markupWord, start: p, end: max(i, p + 1))

        case .lyrics:
            if c == UInt8(ascii: "{") { return tok(.openBrace, 1) }
            if c == UInt8(ascii: "}") { return tok(.closeBrace, 1) }
            if c == UInt8(ascii: "<"), at(p + 1) == UInt8(ascii: "<") { return tok(.openSimultaneous, 2) }
            if c == UInt8(ascii: ">"), at(p + 1) == UInt8(ascii: ">") { return tok(.closeSimultaneous, 2) }
            if Lexer.isDigit(c) { return numberToken(at: p) }
            if c == UInt8(ascii: ".") { return tok(.dot, 1) }
            if c == UInt8(ascii: "*") || c == UInt8(ascii: "/") { return tok(.punctuation, 1) }
            var i = p
            while i < b.count {
                let d = b[i]
                if Lexer.isSpace(d) || Lexer.isDigit(d) || d == UInt8(ascii: "{") || d == UInt8(ascii: "}")
                    || d == UInt8(ascii: "\"") || d == UInt8(ascii: "\\") || d == UInt8(ascii: "#")
                    || d == UInt8(ascii: "$") || d == UInt8(ascii: "%") { break }
                i += 1
            }
            return Token(kind: .lyricWord, start: p, end: i > p ? i : scalarEnd(from: p))

        default:
            break
        }

        switch c {
        case UInt8(ascii: "<"): return at(p + 1) == UInt8(ascii: "<") ? tok(.openSimultaneous, 2) : tok(.openChord, 1)
        case UInt8(ascii: ">"): return at(p + 1) == UInt8(ascii: ">") ? tok(.closeSimultaneous, 2) : tok(.closeChord, 1)
        case UInt8(ascii: "{"): return tok(.openBrace, 1)
        case UInt8(ascii: "}"): return tok(.closeBrace, 1)
        case UInt8(ascii: "("): return tok(.openParen, 1)
        case UInt8(ascii: ")"): return tok(.closeParen, 1)
        case UInt8(ascii: "["): return tok(.openBracket, 1)
        case UInt8(ascii: "]"): return tok(.closeBracket, 1)
        case UInt8(ascii: "~"): return tok(.tie, 1)
        case UInt8(ascii: "|"): return tok(.barCheck, 1)
        case UInt8(ascii: "="): return tok(.equals, 1)
        case UInt8(ascii: "!"), UInt8(ascii: "?"): return tok(.accidentalMark, 1)
        case UInt8(ascii: "."): return tok(.dot, 1)
        case UInt8(ascii: "'"), UInt8(ascii: ","):
            var i = p + 1
            while i < b.count, b[i] == UInt8(ascii: "'") || b[i] == UInt8(ascii: ",") { i += 1 }
            return Token(kind: .octaveMarks, start: p, end: i)
        case UInt8(ascii: "-"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            // In figured bass, "7-" is a flat seven: no articulations there.
            if mode == .figures { return tok(.punctuation, 1) }
            return Lexer.shorthand.contains(at(p + 1)) ? tok(.articulation, 2) : tok(.direction, 1)
        default:
            break
        }
        if Lexer.isDigit(c) { return numberToken(at: p) }
        if Lexer.isLetter(c) { return Token(kind: .word, start: p, end: max(identifierEnd(from: p), scalarEnd(from: p))) }
        if c < 0x80 { return tok(.punctuation, 1) }
        return Token(kind: .unknown, start: p, end: scalarEnd(from: p))
    }

    func numberToken(at p: Int) -> Token {
        var i = p
        while i < b.count, Lexer.isDigit(b[i]) { i += 1 }
        if at(i) == UInt8(ascii: "."), Lexer.isDigit(at(i + 1)) {
            i += 1
            while i < b.count, Lexer.isDigit(b[i]) { i += 1 }
        }
        return Token(kind: .number, start: p, end: i)
    }
}
