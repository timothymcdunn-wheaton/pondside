import Foundation

/// A `\lexicon "id" #'((name . value) …)` (or a graphic's
/// `\startGraphic "id" #'(…)`) in a score, found statically so
/// mistakes are caught before compiling: unknown entries, unknown params,
/// values out of range. (LilyPond would only say "wrong type argument".)
public struct LexiconUse: Hashable, Sendable {
    public var id: String
    public var params: [String: TOMLValue]
    /// UTF-8 offset of `\lexicon`.
    public var offset: Int
    public var line: Int

    /// Every use in `text`. Strings and comments are skipped.
    public static func find(in text: String) -> [LexiconUse] {
        let b = Array(text.utf8)
        var out: [LexiconUse] = []
        var i = 0
        var line = 1
        let commands = [Array("\\lexicon".utf8), Array("\\startGraphic".utf8)]
        func skipSpace(_ j: inout Int) {
            while j < b.count, b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x0A || b[j] == 0x0D { j += 1 }
        }
        while i < b.count {
            let c = b[i]
            if c == 0x0A { line += 1; i += 1; continue }
            if c == UInt8(ascii: "%") {
                // %{ block %} or line comment.
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "{") {
                    i += 2
                    while i + 1 < b.count, !(b[i] == UInt8(ascii: "%") && b[i + 1] == UInt8(ascii: "}")) {
                        if b[i] == 0x0A { line += 1 }
                        i += 1
                    }
                    i += 2
                } else {
                    while i < b.count, b[i] != 0x0A { i += 1 }
                }
                continue
            }
            if c == UInt8(ascii: "\"") {
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "\"") {
                    if b[i] == UInt8(ascii: "\\") { i += 1 }
                    if i < b.count, b[i] == 0x0A { line += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            guard c == UInt8(ascii: "\\"), let command = commands.first(where: { command in
                i + command.count <= b.count && Array(b[i..<(i + command.count)]) == command
                    && (i + command.count == b.count || !Self.isWordByte(b[i + command.count]))
            }) else {
                i += 1
                continue
            }
            let start = i
            var j = i + command.count
            skipSpace(&j)
            guard j < b.count, b[j] == UInt8(ascii: "\"") else { i = j; continue }
            var k = j + 1
            while k < b.count, b[k] != UInt8(ascii: "\"") { k += 1 }
            let id = String(decoding: b[(j + 1)..<min(k, b.count)], as: UTF8.self)
            k += 1
            skipSpace(&k)
            var params: [String: TOMLValue] = [:]
            if k + 1 < b.count, b[k] == UInt8(ascii: "#"), b[k + 1] == UInt8(ascii: "'") {
                var m = k + 2
                params = parseAlist(b, &m)
                k = m
            }
            out.append(LexiconUse(id: id, params: params, offset: start, line: line))
            i = k
        }
        return out
    }

    /// `((density . 0.8) (label . "x"))` → values, as a use's params.
    public static func params(fromAlist text: String) -> [String: TOMLValue] {
        var i = 0
        return parseAlist(Array(text.utf8), &i)
    }

    static func isWordByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
    }

    /// `((density . 0.8) (label . "ca. 8\"") (on . #t))` → values.
    static func parseAlist(_ b: [UInt8], _ i: inout Int) -> [String: TOMLValue] {
        var out: [String: TOMLValue] = [:]
        func skip() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
        skip()
        guard i < b.count, b[i] == UInt8(ascii: "(") else { return out }
        i += 1
        while true {
            skip()
            guard i < b.count else { return out }
            if b[i] == UInt8(ascii: ")") { i += 1; return out }
            guard b[i] == UInt8(ascii: "(") else { i += 1; continue }
            i += 1
            skip()
            var name = ""
            while i < b.count, b[i] != 0x20, b[i] != UInt8(ascii: "."), b[i] != UInt8(ascii: ")") {
                name.unicodeScalars.append(Unicode.Scalar(b[i]))
                i += 1
            }
            skip()
            guard i < b.count, b[i] == UInt8(ascii: ".") else {
                while i < b.count, b[i] != UInt8(ascii: ")") { i += 1 }
                i += 1
                continue
            }
            i += 1
            skip()
            var value: TOMLValue?
            if i < b.count, b[i] == UInt8(ascii: "(") {
                // (height . (swell 3 0.5 4)): a list value.
                value = parseList(b, &i)
            } else if i < b.count, b[i] == UInt8(ascii: "\"") {
                var s = [UInt8]()
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "\"") {
                    if b[i] == UInt8(ascii: "\\"), i + 1 < b.count { i += 1 }
                    s.append(b[i])
                    i += 1
                }
                i += 1
                value = .string(String(decoding: s, as: UTF8.self))
            } else {
                var t = ""
                while i < b.count, b[i] != 0x20, b[i] != UInt8(ascii: ")"), b[i] != 0x0A {
                    t.unicodeScalars.append(Unicode.Scalar(b[i]))
                    i += 1
                }
                if t == "#t" { value = .bool(true) }
                else if t == "#f" { value = .bool(false) }
                else if let n = Int(t) { value = .integer(n) }
                else if let d = Double(t) { value = .float(d) }
                else if t.contains("/"), let r = rational(t) { value = .float(r) }
                else { value = .string(t) }   // a symbol: an enum value
            }
            skip()
            if i < b.count, b[i] == UInt8(ascii: ")") { i += 1 }
            if let value, !name.isEmpty { out[name] = value }
        }
    }

    /// `(swell 3 0.5 4)` or `((0 . 1) (1 . 2))` → an array; symbols become strings.
    static func parseList(_ b: [UInt8], _ i: inout Int) -> TOMLValue {
        var items: [TOMLValue] = []
        i += 1
        while i < b.count {
            while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            guard i < b.count else { break }
            if b[i] == UInt8(ascii: ")") { i += 1; break }
            if b[i] == UInt8(ascii: "(") { items.append(parseList(b, &i)); continue }
            var t = ""
            while i < b.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: "("), UInt8(ascii: ")")].contains(b[i]) {
                t.unicodeScalars.append(Unicode.Scalar(b[i]))
                i += 1
            }
            if t == "." { continue }
            let text = t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 ? String(t.dropFirst().dropLast()) : t
            if let n = Int(text) { items.append(.integer(n)) }
            else if let d = Double(text) { items.append(.float(d)) }
            else { items.append(.string(text)) }
        }
        return .array(items)
    }

    static func rational(_ t: String) -> Double? {
        let p = t.split(separator: "/")
        guard p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d != 0 else { return nil }
        return n / d
    }
}

extension Lexicon {
    /// Problems with the uses in a score, each with its line.
    public func check(_ text: String) -> [(line: Int, message: String)] {
        LexiconUse.find(in: text).flatMap { use -> [(line: Int, message: String)] in
            guard let l = entries[use.id] else {
                let near = ids.filter { $0.hasPrefix(String(use.id.prefix(3))) }
                return [(use.line, "no Lexicon entry \"\(use.id)\"" + (near.isEmpty ? "" : " (did you mean \(near.joined(separator: ", "))?)"))]
            }
            // Integers are fine where floats are expected.
            var given = use.params
            for p in l.entry.params where p.type == .float {
                if case .integer(let n)? = given[p.name] { given[p.name] = .float(Double(n)) }
            }
            do {
                _ = try l.entry.resolve(given)
                return []
            } catch let e as LexiconProblems {
                return e.problems.map { (use.line, $0.description) }
            } catch {
                return [(use.line, "\(error)")]
            }
        }
    }
}
