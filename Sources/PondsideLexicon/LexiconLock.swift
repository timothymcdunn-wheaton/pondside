import Foundation

/// The versions of the Lexicon entries a score uses, recorded in the score
/// itself as a comment block (DESIGN.md §4), so an old score can say which
/// version it was engraved with and `check` can warn when an entry changed:
///
///     %% pondside-lexicon-lock
///     %%   grain-cloud 1.0.0 core
///     %% end pondside-lexicon-lock
///
/// A comment, so LilyPond ignores it and the file stays the only state.
public enum LexiconLock {
    static let open = "%% pondside-lexicon-lock"
    static let close = "%% end pondside-lexicon-lock"

    public struct Pin: Hashable, Sendable {
        public var id: String
        public var version: String
        public var scope: String
    }

    public static func pins(in text: String) -> [Pin] {
        guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return [] }
        return text[a.upperBound..<b.lowerBound].split(separator: "\n").compactMap { line in
            let words = line.drop { $0 == "%" || $0 == " " }.split(separator: " ").map(String.init)
            return words.count >= 2 ? Pin(id: words[0], version: words[1], scope: words.count > 2 ? words[2] : "") : nil
        }
    }

    /// `text` with its lock block replaced (or added at the end) for `used`.
    public static func updating(_ text: String, lexicon: Lexicon, used: Set<String>) -> String {
        let lines = used.sorted().compactMap { id -> String? in
            guard let l = lexicon.entries[id] else { return nil }
            return "%%   \(id) \(l.entry.version) \(l.scope.rawValue)"
        }
        let block = ([open] + lines + [close]).joined(separator: "\n")
        if let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) {
            return String(text[..<a.lowerBound]) + block + String(text[b.upperBound...])
        }
        return text + (text.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }

    /// Entries whose installed version differs from the one the score locked.
    public static func drift(in text: String, lexicon: Lexicon) -> [String] {
        pins(in: text).compactMap { pin in
            guard let l = lexicon.entries[pin.id] else { return "\(pin.id) \(pin.version) is locked but no longer in the Lexicon" }
            return l.entry.version == pin.version ? nil
                : "\(pin.id) is locked at \(pin.version); the Lexicon now has \(l.entry.version) (\(l.scope.rawValue))"
        }
    }
}
