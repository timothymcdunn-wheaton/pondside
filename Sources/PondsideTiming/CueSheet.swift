import Foundation

/// `cues.json`: every electronics cue with its exact moment and its time
/// in seconds and samples, plus the tempo map that produced them, so a
/// consumer never re-derives anything (DESIGN.md §4).
public struct CueSheet: Codable, Sendable, Hashable {
    public struct Position: Codable, Sendable, Hashable {
        public var measure: Int
        /// 1-based beat in the meter's unit; fractional between beats.
        /// Absent when the dump didn't record the position in the bar.
        public var beat: Double?
        /// Whole notes from the start, exact: "167/4".
        public var moment: String
    }

    public struct Cue: Codable, Sendable, Hashable {
        /// Stable across unrelated edits: derived from the name and its
        /// occurrence, so moving a cue keeps its id.
        public var id: String
        public var name: String
        public var index: Int
        public var position: Position
        public var seconds: Double
        public var samples: Int
        public var handler: String
        /// Where the cue is written; absent for generated cues (Lexicon sounds).
        public var source: TimingLog.Row.Origin?
    }

    public struct TempoStep: Codable, Sendable, Hashable {
        public var moment: String
        public var seconds: Double
        /// Quarter notes per minute (timing.ily's unit; any `\tempo` unit
        /// is converted).
        public var bpm: Double
    }

    public struct Mark: Codable, Sendable, Hashable {
        public var text: String
        public var position: Position
        public var seconds: Double
    }

    public var schema = 1
    public var score: String
    public var sampleRate: Int
    public var tempo: [TempoStep]
    public var cues: [Cue]
    /// Other timing marks (`\timingMark "improv 1"`, "end", …).
    public var marks: [Mark]
    /// Seconds to the end mark, else the last event.
    public var duration: Double?
    public var warnings: [String]

    public init(log: TimingLog, score: String, sampleRate: Int = 48000, cuePrefix: String = "cue ") {
        let map = TempoMap(log)
        func position(_ moment: Rational, _ bar: Int, _ inBar: Rational?) -> Position {
            var beat: Double?
            if let inBar {
                let unit = log.meter(at: moment).map { Rational(1, $0.denominator) } ?? Rational(1, 4)
                beat = 1 + (inBar / unit).doubleValue
            }
            return Position(measure: bar, beat: beat, moment: moment.description)
        }
        var occurrences: [String: Int] = [:]
        var cues: [Cue] = []
        for (i, t) in log.texts(startingWith: cuePrefix).enumerated() {
            let name = String(t.text.dropFirst(cuePrefix.count))
            let n = occurrences[name, default: 0]
            occurrences[name] = n + 1
            let seconds = map.seconds(at: t.moment)
            cues.append(Cue(id: n == 0 ? "cue-\(name)" : "cue-\(name)-\(n + 1)", name: name, index: i + 1,
                            position: position(t.moment, t.bar, t.measurePosition),
                            seconds: seconds, samples: Int((seconds * Double(sampleRate)).rounded()),
                            handler: CueSheet.handlerName(name), source: t.origin))
        }
        var warnings: [String] = map.conflicts.map {
            "two different tempos at moment \($0): a hidden \\playTempo must not share a moment with a printed \\tempo"
        }
        for (name, count) in occurrences where count > 1 {
            warnings.append("cue \(name) appears \(count) times")
        }
        var lastSeconds = -1.0
        for c in cues {
            if c.seconds < lastSeconds { warnings.append("cue \(c.name) comes before the cue printed ahead of it") }
            lastSeconds = c.seconds
        }
        self.score = score
        self.sampleRate = sampleRate
        self.tempo = map.steps.map { TempoStep(moment: $0.moment.description, seconds: $0.seconds, bpm: $0.quartersPerMinute) }
        self.cues = cues
        self.marks = log.texts(startingWith: "").filter { !$0.text.hasPrefix(cuePrefix) }.map {
            Mark(text: $0.text, position: position($0.moment, $0.bar, $0.measurePosition), seconds: map.seconds(at: $0.moment))
        }
        self.duration = log.end.map { map.seconds(at: $0) }
        self.warnings = warnings.sorted()
    }

    /// A SuperCollider symbol for the cue's handler: `cue12`, `fxSwell`.
    public static func handlerName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        guard let first = cleaned.first else { return "cue" }
        if first.isNumber { return "cue" + cleaned }
        return first.lowercased() + cleaned.dropFirst()
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// `seconds<TAB>bar<TAB>cue N`, one per cue: the `piece.cues` format
    /// the existing SuperCollider loader reads (lily_timing.py `cues`).
    public var cuesText: String {
        cues.map { String(format: "%.3f", $0.seconds) + "\t\($0.position.measure)\tcue \($0.name)\n" }.joined()
    }
}
