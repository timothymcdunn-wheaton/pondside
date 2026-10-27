/// Leader chords bound to commands, built from the catalog plus the
/// user's remappings.
///
/// Remapping file (`keymap.txt`, one binding per line):
///
///     # command        = chords, comma separated ("none" unbinds)
///     go.error         = ge, x
///     add.slur         = s
public struct Keymap: Sendable {
    public private(set) var commands: [CommandID: CommandSpec]
    public private(set) var bindings: [Chord: CommandID]
    public let order: [CommandID]

    public init(_ specs: [CommandSpec] = CommandCatalog.standard, remap: [CommandID: [Chord]] = [:]) {
        var commands: [CommandID: CommandSpec] = [:]
        var bindings: [Chord: CommandID] = [:]
        for var spec in specs {
            if let chords = remap[spec.id] { spec.chords = chords }
            commands[spec.id] = spec
            for c in spec.chords { bindings[c] = spec.id }
        }
        self.commands = commands
        self.bindings = bindings
        self.order = specs.map(\.id)
    }

    public var specs: [CommandSpec] { order.compactMap { commands[$0] } }

    public func chords(for id: CommandID) -> [Chord] { commands[id]?.chords ?? [] }

    /// The shortest way to type a command, for hints and popovers:
    /// its menu shortcut if it has one, else its first chord, else its key.
    public func keyHint(for id: CommandID) -> String? {
        guard let spec = commands[id] else { return nil }
        if let s = spec.shortcut { return s.description }
        if let c = spec.chords.first { return c.description }
        return spec.keys.first
    }

    // MARK: Problems

    public enum Problem: Hashable, Sendable, CustomStringConvertible {
        /// Two commands on one chord.
        case conflict(Chord, CommandID, CommandID)
        /// A chord that is a prefix of another can never be completed.
        case shadowed(prefix: Chord, by: CommandID, longer: Chord)
        /// A command with no way to reach it from the keyboard.
        case unreachable(CommandID)
        /// Two keystrokes to nearly everything: at most three after the leader.
        case tooLong(Chord, CommandID)
        case duplicateShortcut(KeyStroke, CommandID, CommandID)

        public var description: String {
            switch self {
            case .conflict(let c, let a, let b): return "\(c) is bound to both \(a) and \(b)"
            case .shadowed(let p, let id, let l): return "\(p) (\(id)) shadows \(l)"
            case .unreachable(let id): return "\(id) has no chord, shortcut or key"
            case .tooLong(let c, let id): return "\(c) (\(id)) needs more than three keys after the leader"
            case .duplicateShortcut(let k, let a, let b): return "\(k) is the shortcut of both \(a) and \(b)"
            }
        }
    }

    /// Everything wrong with the bindings: the keyboard-coverage audit.
    public func problems() -> [Problem] {
        var out: [Problem] = []
        var seen: [Chord: CommandID] = [:]
        var shortcuts: [KeyStroke: CommandID] = [:]
        for spec in specs {
            if spec.chords.isEmpty && spec.shortcut == nil && spec.keys.isEmpty { out.append(.unreachable(spec.id)) }
            for c in spec.chords {
                if let other = seen[c], other != spec.id { out.append(.conflict(c, other, spec.id)) }
                seen[c] = spec.id
                if c.keys.count > 3 { out.append(.tooLong(c, spec.id)) }
            }
            if let s = spec.shortcut {
                if let other = shortcuts[s] { out.append(.duplicateShortcut(s, other, spec.id)) }
                shortcuts[s] = spec.id
            }
        }
        for (short, id) in seen {
            for long in seen.keys where long.keys.count > short.keys.count && long.hasPrefix(short.keys) {
                out.append(.shadowed(prefix: short, by: id, longer: long))
            }
        }
        return out
    }

    // MARK: Hints

    public struct Continuation: Hashable, Sendable {
        public var key: Character
        /// The command's title, or the group's name.
        public var label: String
        /// The command this key completes, or nil for a group.
        public var command: CommandID?
    }

    /// What can follow `prefix` — the hint bar's contents.
    public func continuations(after prefix: [Character]) -> [Continuation] {
        var byKey: [Character: Continuation] = [:]
        for (chord, id) in bindings where chord.keys.count > prefix.count && chord.hasPrefix(prefix) {
            let k = chord.keys[prefix.count]
            if chord.keys.count == prefix.count + 1 {
                byKey[k] = Continuation(key: k, label: commands[id]?.title ?? id.rawValue, command: id)
            } else if byKey[k] == nil {
                let name = prefix.isEmpty ? CommandCatalog.groups[k] : nil
                byKey[k] = Continuation(key: k, label: name ?? "…", command: nil)
            }
        }
        // Groups first in catalog order, then commands alphabetically.
        return byKey.values.sorted {
            if ($0.command == nil) != ($1.command == nil) { return $0.command == nil }
            return String($0.key) < String($1.key)
        }
    }

    // MARK: Remapping

    public enum ParseError: Error, Hashable, Sendable {
        case malformed(line: Int)
        case unknownCommand(String, line: Int)
    }

    /// Parses a remapping file.
    public static func parseRemap(_ text: String, known: Set<CommandID>) throws -> [CommandID: [Chord]] {
        var out: [CommandID: [Chord]] = [:]
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = Substring(raw)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingSpaces
            if trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { throw ParseError.malformed(line: n + 1) }
            let id = CommandID(rawValue: String(trimmed[..<eq].trimmingSpaces))
            guard known.contains(id) else { throw ParseError.unknownCommand(id.rawValue, line: n + 1) }
            let value = trimmed[trimmed.index(after: eq)...].trimmingSpaces
            if value == "none" {
                out[id] = []
                continue
            }
            let chords = value.split(separator: ",").map { Chord(String($0.trimmingSpaces)) }
            guard !chords.isEmpty, chords.allSatisfy({ !$0.keys.isEmpty }) else { throw ParseError.malformed(line: n + 1) }
            out[id] = chords
        }
        return out
    }
}

extension Substring {
    var trimmingSpaces: Substring {
        var s = self
        while let f = s.first, f == " " || f == "\t" || f == "\r" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
        return s
    }
}

/// Follows a chord as it is typed: the leader, then keys, until a command
/// is complete or the keys lead nowhere.
public struct ChordRecognizer: Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Keep going; show these in the hint bar.
        case pending([Keymap.Continuation])
        case command(CommandID)
        /// The keys typed so far match nothing (the chord is abandoned).
        case unbound(String)
    }

    public private(set) var typed: [Character]?

    public init() {}

    public var isActive: Bool { typed != nil }

    /// The leader was pressed.
    public mutating func begin(_ keymap: Keymap) -> Outcome {
        typed = []
        return .pending(keymap.continuations(after: []))
    }

    public mutating func cancel() { typed = nil }

    public mutating func feed(_ key: Character, _ keymap: Keymap) -> Outcome {
        guard var keys = typed else { return .unbound(String(key)) }
        keys.append(key)
        if let id = keymap.bindings[Chord(String(keys))] {
            typed = nil
            return .command(id)
        }
        let next = keymap.continuations(after: keys)
        if next.isEmpty {
            typed = nil
            return .unbound(Chord(String(keys)).description)
        }
        typed = keys
        return .pending(next)
    }
}
