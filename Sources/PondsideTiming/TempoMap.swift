/// Musical time → seconds, exactly as LilyPond's MIDI plays it, so cue
/// times, the mockup render and the patch share one clock.
///
/// MIDI knows only stepped tempos. Fermatas, caesuras and timed sections
/// are hidden tempo steps (`\playTempo`); a ritardando is a run of them.
/// There are deliberately no ramps or holds here that the MIDI would not
/// play (a departure from the first cues.json sketch, DESIGN.md §4).
public struct TempoMap: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public var moment: Rational
        public var quartersPerMinute: Double
        /// Seconds at `moment`.
        public var seconds: Double
    }

    /// LilyPond's MIDI tempo before any `\tempo`.
    public static let defaultTempo = 60.0

    public private(set) var steps: [Step]
    /// Moments where two different tempos were given at once (a printed
    /// `\tempo` and a hidden one): the later row wins, as in the MIDI.
    public private(set) var conflicts: [Rational]

    public init(_ log: TimingLog) {
        var byMoment: [Rational: Double] = [:]
        var conflicts: [Rational] = []
        for r in log.rows {
            guard case .tempo(let q) = r.kind else { continue }
            if let existing = byMoment[r.moment], existing != q, !conflicts.contains(r.moment) { conflicts.append(r.moment) }
            byMoment[r.moment] = q
        }
        self.init(tempos: byMoment.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        self.conflicts = conflicts.sorted()
    }

    /// Tempo changes as (moment, quarter notes per minute), in order.
    public init(tempos: [(Rational, Double)]) {
        var steps = [Step(moment: .zero, quartersPerMinute: Self.defaultTempo, seconds: 0)]
        for (m, q) in tempos where q > 0 {
            let last = steps[steps.count - 1]
            let s = last.seconds + Self.span(from: last.moment, to: m, at: last.quartersPerMinute)
            if m == last.moment {
                steps[steps.count - 1].quartersPerMinute = q
            } else {
                steps.append(Step(moment: m, quartersPerMinute: q, seconds: s))
            }
        }
        self.steps = steps
        self.conflicts = []
    }

    private static func span(from a: Rational, to b: Rational, at qpm: Double) -> Double {
        (b - a).doubleValue * 4 * 60 / qpm
    }

    /// The step in force at `moment` (a change at m applies from m).
    private func stepIndex(at moment: Rational) -> Int {
        var lo = 0, hi = steps.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if steps[mid].moment <= moment { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func tempo(at moment: Rational) -> Double { steps[stepIndex(at: moment)].quartersPerMinute }

    /// The tempo in force at `moment`, in quarters a minute.
    public func quartersPerMinute(at moment: Rational) -> Double {
        steps[stepIndex(at: moment)].quartersPerMinute
    }

    public func seconds(at moment: Rational) -> Double {
        let s = steps[stepIndex(at: moment)]
        return s.seconds + Self.span(from: s.moment, to: moment, at: s.quartersPerMinute)
    }

    /// The moment playing at `seconds` (for a playhead following SC),
    /// in whole notes. Inexact by nature: a double.
    public func moment(atSeconds t: Double) -> Double {
        var i = steps.count - 1
        while i > 0 && steps[i].seconds > t { i -= 1 }
        let s = steps[i]
        return s.moment.doubleValue + (t - s.seconds) * s.quartersPerMinute / (4 * 60)
    }
}
