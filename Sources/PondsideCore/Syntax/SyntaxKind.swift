/// Every kind of node in the concrete syntax tree.
///
/// Leaves are tokens and cover every byte of the source, trivia included, so
/// concatenating the leaves reproduces the file exactly. Interior nodes group
/// tokens into structure LilyPond fixes lexically (blocks, notes, events). They
/// never encode arity or meaning that Scheme could redefine at runtime.
public enum SyntaxKind: UInt8, Sendable, Hashable, CaseIterable {
    // MARK: Trivia
    case whitespace
    case lineComment
    case blockComment

    // MARK: Tokens
    case word            // identifier or bare word
    case pitchName       // a word that names a pitch in the current language
    case restName        // r, R, s
    case chordRepeat     // q
    case drumName
    case lyricWord
    case markupWord
    case command         // \name
    case escapedPunct    // \( \) \< \> \! \\ …
    case string
    case number
    case octaveMarks     // ''' or ,,
    case accidentalMark  // ! or ?
    case octaveCheck     // = followed by marks, e.g. ='
    case dot
    case articulation    // direction + shorthand, e.g. -. -> ^- _
    case direction       // - ^ _ before a post-event
    case chordModifier   // :m7/g in chord mode
    case tremolo         // :16
    case openBrace, closeBrace
    case openSimultaneous, closeSimultaneous   // << >>
    case openChord, closeChord                 // < >
    case openParen, closeParen
    case openBracket, closeBracket
    case tie             // ~
    case barCheck        // |
    case equals
    case punctuation     // anything else structural: ' , . * / : + etc. outside notes
    case hash            // # or $ introducing Scheme
    case schemeText
    case embeddedOpen    // #{
    case embeddedClose   // #}
    case unknown         // bytes LilyPond would reject here

    // MARK: Nodes
    case document
    case sequential      // { … }
    case simultaneous    // << … >>
    case chord           // < … >
    case note            // pitch name + marks + accidental mark + octave check
    case rest
    case duration        // 4.. or 8*2/3 or \breve
    case postEvent
    case event           // a music event: head, duration, post-events
    case lyricEvent
    case scheme          // # or $ followed by a datum
    case embeddedMusic   // #{ … #}
    case assignment      // name =
    case propertyPath    // Staff.TimeSignature.color
    case contextSpec     // Staff = "name"
    case pitchArgument   // the pitch after \relative, \key, \transpose …

    public var isTrivia: Bool {
        self == .whitespace || self == .lineComment || self == .blockComment
    }

    public var isToken: Bool { rawValue < SyntaxKind.document.rawValue }
}
