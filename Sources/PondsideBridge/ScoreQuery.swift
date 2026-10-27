import PondsideCore

/// A score's events as data, for agents: what is where, exactly. Pitches
/// are absolute and in Dutch names whatever the file's language, so an
/// agent never has to resolve `\relative` itself.
public enum ScoreQuery {
    public static func events(in text: String, fromLine: Int? = nil, toLine: Int? = nil) -> JSONValue {
        let tree = SyntaxTree(text)
        let source = SourceText(text)
        var out: [JSONValue] = []
        for e in tree.events {
            let index = text.utf8.index(text.utf8.startIndex, offsetBy: e.range.lowerBound)
            let p = source.position(of: index)
            if let fromLine, p.line < fromLine { continue }
            if let toLine, p.line > toLine { break }
            let pitches: [JSONValue] = e.notes.map { n in
                let a = tree.notes[n].absolute
                return .string(PitchLanguage.nederlands.spell(step: a.step, alteration: a.alteration) + OctaveRules.markText(a.octave))
            }
            out.append([
                "kind": .string(kind(e.kind)),
                "text": .string(tree.string(e.range)),
                "line": .number(Double(p.line)),
                "character": .number(Double(p.character)),
                "pitches": .array(pitches),
                "duration": .string(e.effectiveDuration.text),
                "explicitDuration": .bool(e.explicitDuration != nil),
            ])
        }
        return .array(out)
    }

    static func kind(_ k: MusicEvent.Kind) -> String {
        switch k {
        case .note: return "note"
        case .chord: return "chord"
        case .rest: return "rest"
        case .multiMeasureRest: return "multiMeasureRest"
        case .spacer: return "spacer"
        case .chordRepeat: return "chordRepeat"
        case .lyric: return "lyric"
        case .drum: return "drum"
        case .repeatedPitch: return "repeatedPitch"
        }
    }
}
