import XCTest
@testable import PondsideCore

/// Absolute pitches of event notes as "step:alteration:octave" (octave in
/// Pondside convention: c' = 1, i.e. LilyPond's ly:pitch-octave + 1).
func pitches(_ source: String) -> [String] {
    let tree = SyntaxTree(source)
    return tree.notes.filter { $0.role == .event }.map {
        "\($0.absolute.step):\($0.absolute.alteration):\($0.absolute.octave)"
    }
}

func durations(_ source: String) -> [String] {
    SyntaxTree(source).events.map(\.effectiveDuration.text)
}

final class LosslessTests: XCTestCase {
    func testReconstructsExactly() {
        let samples = [
            "",
            "\\version \"2.24.0\"\n{ c'4 d'8( e') | f'2~ f'4 r }\n",
            "%{ block\ncomment %}\n\\relative c'' { <c e g>4-. q8\\f <<{ a }\\\\{ b }>> }",
            "x = #(define-music-function (m) (ly:music?) #{ \\tempo 4 = 60 $m #})",
            "\\lyricmode { Twin4 -- kle __ \"a b\" _ }",
            "\\markup \\bold { \\italic x 100% }  % trailing",
            "{ c4:32 \\chordmode { c1:m7/g } \\drums { bd4 sn } \\figures { <6 4>2 } }",
            "{ c4 } } >> #} stray closers and \u{1D11E} unicode é",
            "unterminated { c4 \"string",
        ]
        for s in samples {
            let tree = SyntaxTree(s)
            XCTAssertEqual(tree.reconstructed, s)
            var covered = 0
            tree.root.forEachLeaf { leaf in
                XCTAssertEqual(leaf.range.lowerBound, covered, "gap before leaf in \(s.debugDescription)")
                covered = leaf.range.upperBound
            }
            XCTAssertEqual(covered, s.utf8.count)
        }
    }

    func testStrayClosersAreReported() {
        XCTAssertFalse(SyntaxTree("{ c } }").issues.isEmpty)
        XCTAssertFalse(SyntaxTree("{ c").issues.isEmpty)
        XCTAssertTrue(SyntaxTree("{ c d e }").issues.isEmpty)
    }
}

final class StructureTests: XCTestCase {
    func testEventsAndPostEvents() {
        let s = "{ c'4.-> d'8( e'16) \\tuplet 3/2 { f'8 g' a' } b'2\\fermata }"
        let tree = SyntaxTree(s)
        XCTAssertEqual(tree.events.count, 7)
        let c = tree.events[0]
        XCTAssertEqual(tree.string(c.range), "c'4.->")
        XCTAssertEqual(c.duration.map(tree.string), "4.")
        XCTAssertEqual(c.postEvents.map(tree.string), ["->"])
        XCTAssertEqual(tree.events[1].postEvents.map(tree.string), ["("])
        XCTAssertEqual(tree.events[6].postEvents.map(tree.string), ["\\fermata"])
        // "3/2" after \tuplet is not an event.
        XCTAssertFalse(tree.events.contains { tree.string($0.range).hasPrefix("3") })
    }

    func testWhitespaceBetweenNoteAndPostEvent() {
        let tree = SyntaxTree("{ c4 ( d) e \\f f -. }")
        XCTAssertEqual(tree.events.map { tree.string($0.range) }, ["c4 (", "d)", "e \\f", "f -."])
    }

    func testChords() {
        let tree = SyntaxTree("{ <c' e'-1 g'>2.~ q4 }")
        XCTAssertEqual(tree.events.count, 2)
        XCTAssertEqual(tree.events[0].kind, .chord)
        XCTAssertEqual(tree.events[0].notes.count, 3)
        XCTAssertEqual(tree.string(tree.events[0].range), "<c' e'-1 g'>2.~")
        XCTAssertEqual(tree.events[1].kind, .chordRepeat)
    }

    func testIdentifiersAreNotNotes() {
        let s = """
        \\header { title = "A" composer = "B" }
        melody = \\relative c' { \\clef bass \\key g \\major \\time 3/4 \\set Staff.instrumentName = "Vc" a4 }
        \\new Staff = "a" \\with { instrumentName = "b" } \\new Voice = f { e }
        \\override Staff.TimeSignature.color = #red
        \\repeat volta 2 { d }
        """
        let tree = SyntaxTree(s)
        let eventTexts = tree.events.map { tree.string($0.range) }
        XCTAssertEqual(eventTexts, ["a4", "e", "d"])
        // \key's pitch is an argument, not an event.
        XCTAssertEqual(tree.notes.filter { $0.role == .absoluteArgument }.count, 1)
    }

    func testModes() {
        let s = """
        \\new Lyrics \\lyricsto "mel" { Here we go a -- long the road __ }
        \\chordmode { c2:m7 g:7/b }
        \\drums { bd4 hh8 sn }
        \\markup { c d e }
        { c4^\\markup { \\italic dolce } d-\\markup \\bold "x" e }
        """
        let tree = SyntaxTree(s)
        let kinds = tree.events.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .lyric }.count, 7)
        XCTAssertEqual(kinds.filter { $0 == .drum }.count, 3)
        // chord-mode roots c and g, plus c d e in music.
        XCTAssertEqual(kinds.filter { $0 == .note }.count, 5)
        // Markup words are never notes.
        XCTAssertFalse(tree.events.contains { tree.string($0.range) == "dolce" })
    }

    func testSchemeAndEmbeddedMusic() {
        let s = "#(define (f x) (list #\\( \"a)\" ; comment )\n #{ c4 d #}))\n{ e }"
        let tree = SyntaxTree(s)
        XCTAssertEqual(tree.events.map { tree.string($0.range) }, ["c4", "d", "e"])
        XCTAssertTrue(tree.issues.isEmpty)
    }

    func testLanguages() {
        let s = "\\language \"english\" { cs4 ef bf dqs c-sharp }\n\\language \"deutsch\" { h b es }\n\\language \"italiano\" { do re mib sold }"
        XCTAssertEqual(pitches(s), [
            "0:2:0", "2:-2:0", "6:-2:0", "1:1:0", "0:2:0",
            "6:0:0", "6:-2:0", "2:-2:0",
            "0:0:0", "1:0:0", "2:-2:0", "4:2:0",
        ])
    }
}

/// Every expectation here was observed from LilyPond 2.24.3 with an event
/// listener (see EngraveTests/OracleTests and DESIGN.md §6).
final class SemanticsTests: XCTestCase {
    func testDurationsInheritLexicallyWithMultipliers() {
        XCTAssertEqual(durations("{ c'4*2 d' e'2*1/2 f' r1*1/4 g' }\n{ a b }"),
                       ["4*2", "4*2", "2*1/2", "2*1/2", "1*1/4", "1*1/4", "1*1/4", "1*1/4"])
        XCTAssertEqual(durations("{ c'4 \\tuplet 3/2 { d'8 e' f' } g' }"), ["4", "8", "8", "8", "8"])
    }

    func testRelativeChainsAcrossVoices() {
        XCTAssertEqual(pitches("\\relative c' { << { e g } \\\\ { c, d } >> f }"),
                       ["2:0:1", "4:0:1", "0:0:1", "1:0:1", "3:0:1"])
        XCTAssertEqual(pitches("\\relative c' { << { c } { g'' } >> d }"), ["0:0:1", "4:0:2", "1:0:2"])
        XCTAssertEqual(pitches("\\relative c' { << { g'' } { c,,, } >> d }"), ["4:0:2", "0:0:0", "1:0:0"])
    }

    func testRelativeWithoutStartPitchIsAbsoluteForTheFirstNote() {
        XCTAssertEqual(pitches("\\relative { c' d g, }"), ["0:0:1", "1:0:1", "4:0:0"])
        XCTAssertEqual(pitches("\\relative { e'' }"), ["2:0:2"])
    }

    func testChordsReferToTheirFirstNote() {
        XCTAssertEqual(pitches("\\relative c' { <c e g> f <g' b d> e }"),
                       ["0:0:1", "2:0:1", "4:0:1", "3:0:1", "4:0:2", "6:0:2", "1:0:3", "2:0:2"])
        XCTAssertEqual(pitches("\\relative c' { <c e g''> d }"), ["0:0:1", "2:0:1", "4:0:3", "1:0:1"])
    }

    func testRepeatsChainLexically() {
        XCTAssertEqual(pitches("\\relative c' { \\repeat volta 2 { c g' } \\alternative { { b } { d } } e }"),
                       ["0:0:1", "4:0:1", "6:0:1", "1:0:2", "2:0:2"])
    }

    func testTransposeArgumentsJoinTheChain() {
        XCTAssertEqual(pitches("\\relative c' { \\transpose c d { c4 e } g }"), ["0:0:0", "2:0:0", "4:0:0"])
    }

    func testNestedScopesAreIsolated() {
        XCTAssertEqual(pitches("\\relative c' { c \\relative c''' { e } g }"), ["0:0:1", "2:0:3", "4:0:0"])
        XCTAssertEqual(pitches("\\relative c' { c \\fixed c'' { e } g }"), ["0:0:1", "2:0:2", "4:0:0"])
        XCTAssertEqual(pitches("\\relative c' { c4 \\absolute { e'' } g }"), ["0:0:1", "2:0:2", "4:0:0"])
    }

    func testKeyAndTranspositionArgumentsDoNotChain() {
        XCTAssertEqual(pitches("\\relative c' { c \\key b \\major g' \\transposition f g }"),
                       ["0:0:1", "4:0:1", "4:0:1"])
    }

    func testOctaveCheckPinsThePitch() {
        XCTAssertEqual(pitches("\\relative c' { c4 c='' d }"), ["0:0:1", "0:0:2", "1:0:2"])
    }

    func testRestsDoNotBreakTheChain() {
        XCTAssertEqual(pitches("\\relative c' { c4 R1 d4 s4 e4 r f }"), ["0:0:1", "1:0:1", "2:0:1", "3:0:1"])
    }

    func testEnglishRelative() {
        XCTAssertEqual(pitches("\\language \"english\"\n\\relative c' { cs4 ef bf' dqs }"),
                       ["0:2:1", "2:-2:1", "6:-2:1", "1:1:2"])
    }
}

final class IncludeTests: XCTestCase {
    func testIncludesRecordTheLanguageInEffect() {
        let tree = SyntaxTree("\\include \"a.ily\"\n\\language \"english\"\n\\include \"b.ily\"\n{ cs }")
        XCTAssertEqual(tree.includes.map(\.path), ["a.ily", "b.ily"])
        XCTAssertEqual(tree.includes.map(\.language), [.nederlands, .english])
        XCTAssertEqual(tree.finalLanguage, .english)
    }

    func testIncludedFilesCanChangeTheLanguage() {
        // defs.ily switches to English; the music after the include follows.
        let tree = SyntaxTree("\\include \"defs.ily\"\n{ cs4 fs }", includedLanguage: { $0 == "defs.ily" ? .english : nil })
        XCTAssertEqual(pitches(tree.text) .count, 0, "parsed alone, cs and fs are not Dutch notes")
        XCTAssertEqual(tree.notes.map(\.absolute.alteration), [2, 2])
        XCTAssertEqual(tree.finalLanguage, .english)
    }

    func testEntryLanguage() {
        XCTAssertEqual(SyntaxTree("{ bf4 }", language: .english).notes.map(\.absolute.alteration), [-2])
    }
}
