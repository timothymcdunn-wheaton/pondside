/// LilyPond note-name languages (`\language "…"`).
///
/// Parsing accepts every spelling LilyPond does for the supported languages;
/// spelling produces the short canonical form, or the long `-sharp` form in
/// English when the original note used it.
public enum PitchLanguage: String, Sendable, Hashable, CaseIterable {
    case nederlands, english, deutsch, italiano, francais, espanol

    /// Maps a `\language` argument (including aliases) to a language.
    public init?(languageName: String) {
        switch languageName {
        case "nederlands", "dutch": self = .nederlands
        case "english": self = .english
        case "deutsch", "german": self = .deutsch
        case "italiano", "italian": self = .italiano
        case "francais", "français", "french": self = .francais
        case "espanol", "español", "spanish": self = .espanol
        default: return nil
        }
    }

    /// Legacy `\include "english.ly"` style language selection.
    public init?(includeFile: String) {
        guard includeFile.hasSuffix(".ly") else { return nil }
        self.init(languageName: String(includeFile.dropLast(3)))
    }

    private var baseNames: [(String, Int)] {
        switch self {
        case .nederlands, .english:
            return [("c", 0), ("d", 1), ("e", 2), ("f", 3), ("g", 4), ("a", 5), ("b", 6)]
        case .deutsch:
            return [("c", 0), ("d", 1), ("e", 2), ("f", 3), ("g", 4), ("a", 5), ("h", 6)]
        case .italiano, .espanol:
            return [("do", 0), ("re", 1), ("mi", 2), ("fa", 3), ("sol", 4), ("la", 5), ("si", 6)]
        case .francais:
            return [("do", 0), ("ré", 1), ("re", 1), ("mi", 2), ("fa", 3), ("sol", 4), ("la", 5), ("si", 6)]
        }
    }

    /// Suffix → alteration in quarter tones.
    private var suffixes: [(String, Int)] {
        switch self {
        case .nederlands, .deutsch:
            return [("", 0), ("is", 2), ("es", -2), ("isis", 4), ("eses", -4),
                    ("ih", 1), ("eh", -1), ("isih", 3), ("eseh", -3)]
        case .english:
            return [("", 0), ("s", 2), ("f", -2), ("ss", 4), ("x", 4), ("ff", -4),
                    ("qs", 1), ("qf", -1), ("tqs", 3), ("tqf", -3),
                    ("-sharp", 2), ("-flat", -2), ("-sharpsharp", 4), ("-flatflat", -4),
                    ("sharp", 2), ("flat", -2), ("sharpsharp", 4), ("flatflat", -4)]
        case .italiano:
            return [("", 0), ("d", 2), ("b", -2), ("dd", 4), ("bb", -4),
                    ("sd", 1), ("sb", -1), ("dsd", 3), ("bsb", -3)]
        case .francais:
            return [("", 0), ("d", 2), ("b", -2), ("dd", 4), ("x", 4), ("bb", -4),
                    ("sd", 1), ("sb", -1), ("dsd", 3), ("bsb", -3)]
        case .espanol:
            return [("", 0), ("s", 2), ("b", -2), ("ss", 4), ("x", 4), ("bb", -4),
                    ("cs", 1), ("cb", -1), ("tcs", 3), ("tcb", -3)]
        }
    }

    /// Parses a pitch name (without octave marks). Returns step and
    /// alteration, or nil if the word is not a pitch in this language.
    public func parse<S: StringProtocol>(_ word: S) -> (step: Int, alteration: Int)? {
        let w = String(word)
        // Dutch/German contractions: es/as/eses/ases (and long forms ees/aes).
        if self == .nederlands || self == .deutsch {
            switch w {
            case "es": return (2, -2)
            case "eses": return (2, -4)
            case "eseh": return (2, -3)
            case "as": return (5, -2)
            case "ases": return (5, -4)
            case "aseh": return (5, -3)
            default: break
            }
        }
        if self == .deutsch {
            switch w {
            case "b": return (6, -2)
            case "heses": return (6, -4)
            case "beh": return (6, -3)
            default: break
            }
        }
        for (base, step) in baseNames where w.hasPrefix(base) {
            let suffix = String(w.dropFirst(base.count))
            for (s, alteration) in suffixes where s == suffix {
                return (step, alteration)
            }
        }
        return nil
    }

    /// Spells a pitch name. `longForm` selects English `-sharp` names.
    public func spell(step: Int, alteration: Int, longForm: Bool = false) -> String {
        switch self {
        case .nederlands, .deutsch:
            if self == .deutsch && step == 6 && alteration == -2 { return "b" }
            if step == 2 || step == 5 {
                let base = step == 2 ? "e" : "a"
                switch alteration {
                case -2: return base == "e" ? "es" : "as"
                case -4: return base == "e" ? "eses" : "ases"
                case -3: return base == "e" ? "eseh" : "aseh"
                default: break
                }
            }
        case .english:
            if longForm {
                let longSuffix = [-4: "-flatflat", -2: "-flat", 2: "-sharp", 4: "-sharpsharp"]
                if let s = longSuffix[alteration] { return baseNames[step].0 + s }
            }
        default:
            break
        }
        let base = baseNames.first { $0.1 == step }!.0
        let suffix = suffixes.first { $0.1 == alteration && !$0.0.hasPrefix("-") }?.0 ?? ""
        return base + suffix
    }
}
