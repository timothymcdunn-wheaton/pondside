/// An absolute or written pitch.
///
/// `step` is 0…6 for C…B. `alteration` is in quarter tones (2 = sharp,
/// -2 = flat). `octave` counts LilyPond octave marks in absolute entry, so
/// `c` (the C below middle C) is octave 0 and `c'` (middle C) is octave 1.
/// LilyPond's internal `ly:pitch-octave` is this value minus one.
public struct Pitch: Hashable, Sendable, CustomStringConvertible {
    public var step: Int
    public var alteration: Int
    public var octave: Int

    public init(step: Int, alteration: Int = 0, octave: Int) {
        self.step = step
        self.alteration = alteration
        self.octave = octave
    }

    /// Diatonic index across octaves; what relative-octave entry compares.
    public var diatonicIndex: Int { octave * 7 + step }

    public var semitones: Int {
        let natural = [0, 2, 4, 5, 7, 9, 11][step]
        return octave * 12 + natural + alteration / 2
    }

    public init(diatonicIndex: Int, alteration: Int) {
        let octave = diatonicIndex >= 0 ? diatonicIndex / 7 : (diatonicIndex - 6) / 7
        self.init(step: diatonicIndex - octave * 7, alteration: alteration, octave: octave)
    }

    /// The reference pitch LilyPond uses for `\relative` with no start pitch:
    /// the F below middle C, which makes the first note read as absolute.
    public static let relativeDefault = Pitch(step: 3, octave: 0)

    public var description: String {
        let marks = octave > 0 ? String(repeating: "'", count: octave) : String(repeating: ",", count: -octave)
        return PitchLanguage.nederlands.spell(step: step, alteration: alteration) + marks
    }
}

/// How a note's written octave marks map to an absolute octave.
public enum OctaveMode: Hashable, Sendable {
    case absolute
    /// `\fixed`: marks are relative to a fixed octave.
    case fixed(baseOctave: Int)
    /// `\relative`: marks are relative to the previous pitch in the chain.
    case relative
}

/// Octave arithmetic for LilyPond's three entry modes.
public enum OctaveRules {
    /// In relative mode, the octave in which `step` lies closest (within a
    /// fourth, counted in staff positions) to `reference`.
    public static func nearestOctave(step: Int, to reference: Pitch) -> Int {
        let r = reference.diatonicIndex
        // Candidates within ±3 steps: exactly one octave qualifies.
        for octave in (reference.octave - 1)...(reference.octave + 1) {
            let d = octave * 7 + step - r
            if d >= -3 && d <= 3 { return octave }
        }
        return reference.octave
    }

    /// The absolute octave for `marks` written on `step`.
    public static func absoluteOctave(step: Int, marks: Int, mode: OctaveMode, reference: Pitch?) -> Int {
        switch mode {
        case .absolute: return marks
        case .fixed(let base): return base + marks
        case .relative: return nearestOctave(step: step, to: reference ?? .relativeDefault) + marks
        }
    }

    /// The marks to write for an absolute octave.
    public static func marks(for pitch: Pitch, mode: OctaveMode, reference: Pitch?) -> Int {
        switch mode {
        case .absolute: return pitch.octave
        case .fixed(let base): return pitch.octave - base
        case .relative: return pitch.octave - nearestOctave(step: pitch.step, to: reference ?? .relativeDefault)
        }
    }

    public static func markText(_ marks: Int) -> String {
        marks >= 0 ? String(repeating: "'", count: marks) : String(repeating: ",", count: -marks)
    }
}

/// A key signature, for key-aware diatonic stepping.
public struct KeySignature: Hashable, Sendable {
    public var tonic: Pitch
    public var mode: String

    public init(tonic: Pitch, mode: String) {
        self.tonic = tonic
        self.mode = mode
    }

    public static let cMajor = KeySignature(tonic: Pitch(step: 0, octave: 0), mode: "major")

    private static let modes: [String: [Int]] = [
        "major": [0, 2, 4, 5, 7, 9, 11], "ionian": [0, 2, 4, 5, 7, 9, 11],
        "minor": [0, 2, 3, 5, 7, 8, 10], "aeolian": [0, 2, 3, 5, 7, 8, 10],
        "dorian": [0, 2, 3, 5, 7, 9, 10], "phrygian": [0, 1, 3, 5, 7, 8, 10],
        "lydian": [0, 2, 4, 6, 7, 9, 11], "mixolydian": [0, 2, 4, 5, 7, 9, 10],
        "locrian": [0, 1, 3, 5, 6, 8, 10],
    ]

    public static func isMode(_ name: String) -> Bool { modes[name] != nil }

    /// The alteration (quarter tones) this key gives `step`.
    public func alteration(for step: Int) -> Int {
        let intervals = Self.modes[mode] ?? Self.modes["major"]!
        let degree = ((step - tonic.step) % 7 + 7) % 7
        let natural = [0, 2, 4, 5, 7, 9, 11]
        // Work in quarter tones; reduce to the representation nearest natural.
        let target = natural[tonic.step] * 2 + tonic.alteration + intervals[degree] * 2
        var diff = (target - natural[step] * 2) % 24
        if diff > 12 { diff -= 24 }
        if diff <= -12 { diff += 24 }
        return diff
    }
}
