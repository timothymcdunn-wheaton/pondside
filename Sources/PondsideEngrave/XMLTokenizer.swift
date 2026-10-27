/// A small, fast, forgiving XML tokenizer sufficient for LilyPond's SVG.
///
/// Foundation's XMLParser lives in a separate module on Linux and is a
/// callback-driven SAX parser that is awkward from Swift; LilyPond's SVG
/// output is simple, machine-generated XML, so a byte-level tokenizer is both
/// faster and fully portable.
struct XMLTokenizer {
    enum Token: Equatable {
        case start(name: String, attributes: [String: String], selfClosing: Bool)
        case end(name: String)
        case text(String)
    }

    private let bytes: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(_ string: String) {
        self.init(Array(string.utf8))
    }

    mutating func next() -> Token? {
        while i < bytes.count {
            if bytes[i] != lt {
                let start = i
                while i < bytes.count, bytes[i] != lt { i += 1 }
                return .text(decodeEntities(bytes[start..<i]))
            }
            // Markup.
            if hasPrefix("<!--") {
                skip(past: "-->")
                continue
            }
            if hasPrefix("<![CDATA[") {
                let start = i + 9
                skip(past: "]]>")
                let end = max(start, i - 3)
                return .text(String(decoding: bytes[start..<end], as: UTF8.self))
            }
            if hasPrefix("<?") || hasPrefix("<!") {
                skip(past: ">")
                continue
            }
            if hasPrefix("</") {
                i += 2
                let name = readName()
                skip(past: ">")
                return .end(name: name)
            }
            i += 1
            let name = readName()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while i < bytes.count {
                skipWhitespace()
                guard i < bytes.count else { break }
                if bytes[i] == gt { i += 1; break }
                if bytes[i] == slash {
                    selfClosing = true
                    i += 1
                    continue
                }
                let key = readName()
                if key.isEmpty { i += 1; continue }
                skipWhitespace()
                var value = ""
                if i < bytes.count, bytes[i] == eq {
                    i += 1
                    skipWhitespace()
                    if i < bytes.count, bytes[i] == quote || bytes[i] == apos {
                        let q = bytes[i]
                        i += 1
                        let start = i
                        while i < bytes.count, bytes[i] != q { i += 1 }
                        value = decodeEntities(bytes[start..<min(i, bytes.count)])
                        i += 1
                    }
                }
                attributes[key] = value
            }
            return .start(name: name, attributes: attributes, selfClosing: selfClosing)
        }
        return nil
    }

    // MARK: - Helpers

    private let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
    private let eq = UInt8(ascii: "="), quote = UInt8(ascii: "\""), apos = UInt8(ascii: "'")

    private func hasPrefix(_ s: StaticString) -> Bool {
        let n = s.utf8CodeUnitCount
        guard i + n <= bytes.count else { return false }
        let p = s.utf8Start
        for k in 0..<n where bytes[i + k] != p[k] { return false }
        return true
    }

    private mutating func skip(past s: StaticString) {
        while i < bytes.count, !hasPrefix(s) { i += 1 }
        i = min(bytes.count, i + s.utf8CodeUnitCount)
    }

    private mutating func skipWhitespace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
    }

    private mutating func readName() -> String {
        let start = i
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == gt || b == slash || b == eq { break }
            i += 1
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private func decodeEntities(_ slice: ArraySlice<UInt8>) -> String {
        guard slice.contains(UInt8(ascii: "&")) else { return String(decoding: slice, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        var k = slice.startIndex
        while k < slice.endIndex {
            let b = slice[k]
            guard b == UInt8(ascii: "&"), let semi = slice[k...].prefix(12).firstIndex(of: UInt8(ascii: ";")) else {
                out.append(b)
                k += 1
                continue
            }
            let name = String(decoding: slice[(k + 1)..<semi], as: UTF8.self)
            var scalar: Unicode.Scalar?
            switch name {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    scalar = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if name.hasPrefix("#") {
                    scalar = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init)
                }
            }
            if let scalar {
                out.append(contentsOf: Array(String(scalar).utf8))
                k = semi + 1
            } else {
                out.append(b)
                k += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
