/// A TOML reader for the subset entry.toml and pondside.toml use: tables
/// (`[a.b]`), dotted and quoted keys, basic and literal strings (and their
/// multi-line forms), integers, floats, booleans, arrays (spanning lines,
/// trailing commas) and inline tables. Dates are not supported.
public enum TOMLValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .integer(let i) = self { return i }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    /// Integers read as numbers too.
    public var number: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .float(let d): return d
        default: return nil
        }
    }

    public subscript(_ key: String) -> TOMLValue? { table?[key] }
}

public struct TOMLError: Error, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var p = Parser(Array(text.unicodeScalars))
        return try p.document()
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1
        var root: [String: TOMLValue] = [:]
        var current: [String] = []
        var definedTables: Set<[String]> = []

        init(_ s: [Unicode.Scalar]) { self.s = s }

        func error(_ m: String) -> TOMLError { TOMLError(line: line, message: m) }

        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        /// Spaces, newlines and comments (inside arrays).
        mutating func skipWhitespaceAndComments() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
                else if c == "#" { while let d = peek, d != "\n" { _ = d; advance() } }
                else { break }
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            if peek == "#" { while let c = peek, c != "\n" { _ = c; advance() } }
            if peek == "\r" { advance() }
            guard peek == nil || peek == "\n" else { throw error("expected the end of the line") }
            if peek == "\n" { advance() }
        }

        mutating func document() throws -> [String: TOMLValue] {
            while peek != nil {
                skipWhitespaceAndComments()
                guard let c = peek else { break }
                if c == "[" {
                    advance()
                    if peek == "[" { throw error("arrays of tables are not supported") }
                    skipSpaces()
                    let path = try keyPath()
                    skipSpaces()
                    guard peek == "]" else { throw error("expected ]") }
                    advance()
                    guard definedTables.insert(path).inserted else { throw error("table [\(path.joined(separator: "."))] defined twice") }
                    try ensureTable(path)
                    current = path
                    try endOfLine()
                } else {
                    let path = try keyPath()
                    skipSpaces()
                    guard peek == "=" else { throw error("expected = after \(path.joined(separator: "."))") }
                    advance()
                    skipSpaces()
                    let v = try value()
                    try set(current + path, v)
                    try endOfLine()
                }
            }
            return root
        }

        mutating func keyPath() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = peek else { throw error("expected a key") }
                if c == "\"" || c == "'" {
                    guard case .string(let k) = try stringValue() else { throw error("bad key") }
                    parts.append(k)
                } else {
                    var k = ""
                    while let d = peek, d.properties.isAlphabetic || ("0"..."9").contains(d) || d == "-" || d == "_" {
                        k.unicodeScalars.append(d)
                        advance()
                    }
                    guard !k.isEmpty else { throw error("expected a key") }
                    parts.append(k)
                }
                skipSpaces()
                if peek == "." { advance() } else { return parts }
            }
        }

        mutating func ensureTable(_ path: [String]) throws {
            func make(_ t: inout [String: TOMLValue], _ rest: ArraySlice<String>) throws {
                guard let k = rest.first else { return }
                var sub: [String: TOMLValue]
                switch t[k] {
                case nil: sub = [:]
                case .table(let existing)?: sub = existing
                default: throw error("\(k) is already a value, not a table")
                }
                try make(&sub, rest.dropFirst())
                t[k] = .table(sub)
            }
            try make(&root, path[...])
        }

        mutating func set(_ path: [String], _ v: TOMLValue) throws {
            func put(_ t: inout [String: TOMLValue], _ rest: ArraySlice<String>) throws {
                let k = rest.first!
                if rest.count == 1 {
                    guard t[k] == nil else { throw error("\(k) is defined twice") }
                    t[k] = v
                    return
                }
                var sub: [String: TOMLValue]
                switch t[k] {
                case nil: sub = [:]
                case .table(let existing)?: sub = existing
                default: throw error("\(k) is already a value, not a table")
                }
                try put(&sub, rest.dropFirst())
                t[k] = .table(sub)
            }
            try put(&root, path[...])
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw error("expected a value") }
            switch c {
            case "\"", "'": return try stringValue()
            case "[": return try arrayValue()
            case "{": return try inlineTable()
            case "t", "f": return try boolValue()
            default: return try numberValue()
            }
        }

        mutating func boolValue() throws -> TOMLValue {
            for (word, v) in [("true", true), ("false", false)] {
                let w = Array(word.unicodeScalars)
                if i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w {
                    for _ in w { advance() }
                    return .bool(v)
                }
            }
            throw error("expected a value")
        }

        mutating func numberValue() throws -> TOMLValue {
            var text = ""
            while let c = peek, ("0"..."9").contains(c) || c == "-" || c == "+" || c == "." || c == "e" || c == "E" || c == "_" {
                if c != "_" { text.unicodeScalars.append(c) }
                advance()
            }
            if let n = Int(text) { return .integer(n) }
            if let d = Double(text), text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return .float(d) }
            throw error(text.isEmpty ? "expected a value" : "\(text) is not a number")
        }

        mutating func arrayValue() throws -> TOMLValue {
            advance()
            var items: [TOMLValue] = []
            while true {
                skipWhitespaceAndComments()
                if peek == "]" { advance(); return .array(items) }
                items.append(try value())
                skipWhitespaceAndComments()
                if peek == "," { advance(); continue }
                guard peek == "]" else { throw error("expected , or ] in an array") }
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            advance()
            var t: [String: TOMLValue] = [:]
            skipSpaces()
            if peek == "}" { advance(); return .table(t) }
            while true {
                let path = try keyPath()
                skipSpaces()
                guard peek == "=" else { throw error("expected = in an inline table") }
                advance()
                skipSpaces()
                let v = try value()
                guard path.count == 1, t[path[0]] == nil else { throw error("bad or repeated key in an inline table") }
                t[path[0]] = v
                skipSpaces()
                if peek == "," { advance(); skipSpaces(); continue }
                guard peek == "}" else { throw error("expected , or } in an inline table") }
                advance()
                return .table(t)
            }
        }

        mutating func stringValue() throws -> TOMLValue {
            let quote = peek!
            let triple = i + 2 < s.count && s[i + 1] == quote && s[i + 2] == quote
            advance()
            if triple {
                advance(); advance()
                // A newline right after the opening quotes is dropped.
                if peek == "\n" { advance() } else if peek == "\r", i + 1 < s.count, s[i + 1] == "\n" { advance(); advance() }
            }
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if c == quote {
                    if !triple { advance(); return .string(out) }
                    if i + 2 < s.count, s[i + 1] == quote, s[i + 2] == quote {
                        advance(); advance(); advance()
                        return .string(out)
                    }
                }
                if c == "\n" && !triple { throw error("newline in a string") }
                if c == "\\" && quote == "\"" {
                    advance()
                    guard let e = peek else { throw error("unterminated string") }
                    advance()
                    switch e {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "u", "U":
                        let n = e == "u" ? 4 : 8
                        guard i + n <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<(i + n)])), radix: 16),
                              let scalar = Unicode.Scalar(v) else { throw error("bad \\u escape") }
                        for _ in 0..<n { advance() }
                        out.unicodeScalars.append(scalar)
                    case "\n" where triple:
                        // Line-ending backslash: trim the following whitespace.
                        while let w = peek, w == " " || w == "\t" || w == "\n" { advance() }
                    default: throw error("unknown escape \\\(e)")
                    }
                    continue
                }
                out.unicodeScalars.append(c)
                advance()
            }
        }
    }
}
