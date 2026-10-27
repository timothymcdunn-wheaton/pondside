/// A single replacement of a UTF-16 range, in the coordinates text views use.
public struct UTF16Replacement: Hashable, Sendable {
    /// Location and length in the *old* text, in UTF-16 code units.
    public var location: Int
    public var length: Int
    public var replacement: String

    public init(location: Int, length: Int, replacement: String) {
        self.location = location
        self.length = length
        self.replacement = replacement
    }

    /// Applies the replacement. Exposed so tests can prove round-trips.
    public func apply(to old: String) -> String {
        let units = Array(old.utf16)
        let head = units[..<location]
        let tail = units[(location + length)...]
        return String(decoding: head, as: UTF16.self) + replacement + String(decoding: tail, as: UTF16.self)
    }

    /// Maps an offset in the old text to the new text. Offsets inside the
    /// replaced range collapse to its end so a caret ends up after new text.
    public func mapOffset(_ offset: Int) -> Int {
        if offset <= location { return offset }
        let delta = replacement.utf16.count - length
        if offset >= location + length { return offset + delta }
        return location + replacement.utf16.count
    }
}

public enum TextDiff {
    /// The smallest single replacement turning `old` into `new`, found by
    /// trimming the common prefix and suffix. Never splits a surrogate pair.
    ///
    /// Used when an external tool rewrites the file: applying only the
    /// changed span keeps the caret, scroll position and undo history of
    /// every untouched region intact. Returns nil when the texts are equal.
    public static func minimalReplacement(from old: String, to new: String) -> UTF16Replacement? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        if a == b { return nil }

        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        let maxSuffix = min(a.count, b.count) - prefix
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }

        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return UTF16Replacement(location: prefix, length: a.count - suffix - prefix, replacement: replacement)
    }
}

/// FNV-1a, 64-bit. A fast, dependency-free content hash used to recognise
/// our own writes and to key render caches. Not cryptographic.
public struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        value = h
    }

    public init(_ string: String) {
        self.init(bytes: string.utf8)
    }

    public var description: String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
