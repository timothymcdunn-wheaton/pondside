/// Fuzzy matching for the command palette.
///
/// Query characters must appear in order. Matches at word starts and runs
/// of consecutive characters score highest, so "as" finds "Add Slur" and
/// "fit" finds "Fit Width" before "Go to First Note".
public enum FuzzyMatch {
    public struct Result: Hashable, Sendable {
        public var score: Int
        /// Character offsets in the candidate that matched, for bolding.
        public var positions: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Result? {
        let q = Array(query.lowercased().filter { $0 != " " })
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        guard q.count <= c.count else { return nil }

        func isWordStart(_ i: Int) -> Bool {
            if i == 0 { return true }
            let prev = original[i - 1], here = original[i]
            if !(prev.isLetter || prev.isNumber) { return true }
            return prev.isLowercase && here.isUppercase
        }
        let starts = c.indices.map(isWordStart)

        // best[i][j]: best score with q[i] matched at c[j]; DP over positions.
        let none = Int.min / 2
        var best = Array(repeating: Array(repeating: none, count: c.count), count: q.count)
        var from = Array(repeating: Array(repeating: -1, count: c.count), count: q.count)
        for j in c.indices where c[j] == q[0] {
            best[0][j] = (starts[j] ? 10 : 1) + (j == 0 ? 6 : 0) - min(j, 5)
        }
        if q.count > 1 {
            for i in 1..<q.count {
                for j in i..<c.count where c[j] == q[i] {
                    var top = none, arg = -1
                    for k in (i - 1)..<j where best[i - 1][k] > none {
                        let gap = j - k - 1
                        let s = best[i - 1][k] + (gap == 0 ? 8 : (starts[j] ? 10 : 1) - min(gap, 4))
                        if s > top { top = s; arg = k }
                    }
                    best[i][j] = top
                    from[i][j] = arg
                }
            }
        }
        let last = q.count - 1
        guard let end = c.indices.max(by: { best[last][$0] < best[last][$1] }), best[last][end] > none else { return nil }
        var positions = [end]
        var j = end
        for i in stride(from: last, to: 0, by: -1) {
            j = from[i][j]
            positions.append(j)
        }
        // Shorter candidates win ties: "Undo" before "Undo History".
        return Result(score: best[last][end] * 4 - (c.count - q.count) / 4, positions: Array(positions.reversed()))
    }
}

/// Ranks commands for the palette: fuzzy match on the title (and the
/// chord typed as letters), then what makes sense here, then what was
/// used recently.
public struct CommandPalette: Sendable {
    public struct Item: Hashable, Sendable {
        public var spec: CommandSpec
        public var available: Bool
        public var matched: [Int]
        public var hint: String?
    }

    public var keymap: Keymap
    /// Commands run most recently, most recent first.
    public var recent: [CommandID] = []

    public init(keymap: Keymap) { self.keymap = keymap }

    public mutating func noteUsed(_ id: CommandID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 20 { recent.removeLast() }
    }

    public func items(for query: String, in context: CommandContext, onlyAvailable: Bool = false) -> [Item] {
        var scored: [(Item, Int)] = []
        let q = query.lowercased().filter { $0 != " " }
        for spec in keymap.specs {
            let available = spec.isAvailable(in: context)
            if onlyAvailable && !available { continue }
            var score: Int
            var positions: [Int] = []
            if q.isEmpty {
                score = 0
            } else if let m = FuzzyMatch.match(q, in: spec.title) {
                score = m.score
                positions = m.positions
            } else if let g = FuzzyMatch.match(q, in: spec.gloss), g.score > 0 {
                score = g.score / 4
            } else {
                continue
            }
            // Typing a chord's letters finds its command.
            if spec.chords.contains(where: { String($0.keys).lowercased() == q }) { score += 200 }
            if available { score += 60 }
            if let r = recent.firstIndex(of: spec.id) { score += 40 - min(r, 20) * 2 }
            scored.append((Item(spec: spec, available: available, matched: positions, hint: keymap.keyHint(for: spec.id)), score))
        }
        let order = Dictionary(uniqueKeysWithValues: keymap.order.enumerated().map { ($1, $0) })
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return order[$0.0.spec.id, default: 0] < order[$1.0.spec.id, default: 0]
        }.map(\.0)
    }
}
