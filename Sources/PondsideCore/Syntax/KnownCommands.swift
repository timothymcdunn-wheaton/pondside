/// Command names whose lexical role is fixed by LilyPond's own init files.
///
/// This is the only "knowledge" the parser has, and all of it is about
/// tokenization and attachment — never semantics. A score that redefines one
/// of these still round-trips byte for byte; at worst it is grouped
/// differently, and the compiler stays the authority.
enum KnownCommands {
    /// Bare commands that attach to the preceding note as post-events.
    static let postEvents: Set<String> = [
        // dynamics
        "ppppp", "pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fffff",
        "fp", "sf", "sff", "sp", "spp", "sfz", "rfz", "n",
        "cr", "decr", "cresc", "dim", "decresc", "endcresc", "enddecresc", "enddim",
        "crescHairpin", "crescTextCresc", "dimHairpin", "dimTextDim",
        // articulations and ornaments (script-init.ly)
        "accent", "marcato", "staccatissimo", "staccato", "tenuto", "portato", "espressivo",
        "fermata", "shortfermata", "longfermata", "verylongfermata", "veryshortfermata",
        "henzeshortfermata", "henzelongfermata", "fermataMarkup",
        "segno", "coda", "varcoda", "thumb", "lheel", "rheel", "ltoe", "rtoe",
        "open", "halfopen", "snappizzicato", "stopped", "turn", "reverseturn", "trill",
        "prall", "mordent", "prallprall", "prallmordent", "upprall", "downprall",
        "upmordent", "downmordent", "pralldown", "prallup", "lineprall",
        "signumcongruentiae", "flageolet", "upbow", "downbow", "ictus", "accentus",
        "circulus", "semicirculus", "haydnturn", "slashturn",
        // spanners and other event attachments
        "startTrillSpan", "stopTrillSpan", "startTextSpan", "stopTextSpan",
        "startGroup", "stopGroup", "sustainOn", "sustainOff", "sostenutoOn", "sostenutoOff",
        "unaCorda", "treCorde", "glissando", "arpeggio", "laissezVibrer", "repeatTie",
        "harmonic", "noBeam", "startMeasureCount", "stopMeasureCount",
        "startMeasureSpanner", "stopMeasureSpanner",
    ]

    /// Post-event commands that take one following argument.
    static let postEventsWithArgument: Set<String> = ["finger", "bendAfter", "rightHandFinger"]

    /// Commands after which the next pitch(es) are arguments, not events.
    /// The value is how many pitch arguments to expect.
    static let pitchArguments: [String: Int] = [
        "relative": 1, "transpose": 2, "fixed": 1, "key": 1, "transposition": 1,
        "octaveCheck": 1, "inversion": 2, "modalTranspose": 2, "modalInversion": 2,
    ]

    /// Commands whose next words are a property path.
    static let propertyPath: Set<String> = [
        "set", "unset", "override", "revert", "tweak", "overrideProperty", "omit", "hide",
        "propertySet", "propertyUnset", "propertyOverride", "propertyRevert", "propertyTweak",
    ]

    /// Commands whose next word is a context type (and optional `= name`).
    static let contextSpec: Set<String> = ["new", "context", "change"]

    /// Commands whose next word is a plain identifier.
    static let identifierArgument: Set<String> = [
        "clef", "consists", "remove", "accepts", "denies", "alias", "name", "type",
        "defaultchild", "repeat", "lyricsto", "voices",
    ]

    /// Mode-switching commands.
    static let modes: [String: LexMode] = [
        "lyricmode": .lyrics, "lyrics": .lyrics, "addlyrics": .lyrics, "lyricsto": .lyrics,
        "chordmode": .chords, "chords": .chords,
        "figuremode": .figures, "figures": .figures,
        "drummode": .drums, "drums": .drums,
        "notemode": .notes,
        "header": .initial, "paper": .initial, "layout": .initial, "midi": .initial, "with": .initial,
    ]

    static let markupCommands: Set<String> = ["markup", "markuplist", "markuplines"]

    /// Duration-valued commands.
    static let durationNames: Set<String> = ["breve", "longa", "maxima"]

    /// Escaped punctuation that attaches as a post-event.
    static let postEventPunct: Set<String> = ["\\(", "\\)", "\\<", "\\>", "\\!", "\\[", "\\]", "\\="]
}
