import XCTest
@testable import PondsideCore

/// Applies `op` to the event whose text starts at the first occurrence of
/// `anchor`, returning the new source.
func applying(_ source: String, at anchor: String, _ op: (ScoreEditor, Int) -> ScoreEdit?) -> String? {
    let tree = SyntaxTree(source)
    guard let r = source.utf8.firstRange(of: Array(anchor.utf8)) else { return nil }
    let offset = source.utf8.distance(from: source.utf8.startIndex, to: r.lowerBound)
    guard let e = tree.events.firstIndex(where: { $0.range.lowerBound == offset }) else { return nil }
    guard let edit = op(ScoreEditor(tree), e) else { return nil }
    return edit.edits.apply(to: source)
}

final class ScoreEditorTests: XCTestCase {
    func testStepChangesOnlyThePitchCharacters() {
        let src = "{ c'4 d'8 e' }"
        XCTAssertEqual(applying(src, at: "d'8") { $0.move(events: [$1], by: .step(1)) }, "{ c'4 e'8 e' }")
        XCTAssertEqual(applying(src, at: "c'4") { $0.move(events: [$1], by: .step(-1)) }, "{ b4 d'8 e' }")
    }

    func testStepHonoursTheKey() {
        let src = "{ \\key d \\major e'4 b' }"
        XCTAssertEqual(applying(src, at: "e'4") { $0.move(events: [$1], by: .step(1)) }, "{ \\key d \\major fis'4 b' }")
        XCTAssertEqual(applying(src, at: "b'") { $0.move(events: [$1], by: .step(1)) }, "{ \\key d \\major e'4 cis'' }")
    }

    func testRelativeOctaveChangeCompensatesTheNextNote() {
        // Raising d an octave must not drag e (and everything after) along.
        let src = "\\relative c' { c4 d e f }"
        XCTAssertEqual(applying(src, at: "d") { $0.move(events: [$1], by: .octave(1)) },
                       "\\relative c' { c4 d' e, f }")
        XCTAssertEqual(pitches("\\relative c' { c4 d' e, f }"), ["0:0:1", "1:0:2", "2:0:1", "3:0:1"])
    }

    func testRelativeStepAcrossTheFourthBoundary() {
        // c → g would read as the g *below*; the moved note needs a mark,
        // and the following g (now a unison) keeps its pitch unmarked.
        let src = "\\relative c' { c4 f g a }"
        let out = applying(src, at: "f") { $0.move(events: [$1], by: .step(1)) }!
        XCTAssertEqual(out, "\\relative c' { c4 g' g a }")
        XCTAssertEqual(pitches(out), ["0:0:1", "4:0:1", "4:0:1", "5:0:1"])
    }

    func testChromaticKeepsNameStepAndSpelling() {
        XCTAssertEqual(applying("{ e'4 }", at: "e'4") { $0.move(events: [$1], by: .chromatic(-1)) }, "{ es'4 }")
        XCTAssertEqual(applying("\\language \"english\" { c-sharp'4 }", at: "c-sharp") { $0.move(events: [$1], by: .chromatic(1)) },
                       "\\language \"english\" { c-sharpsharp'4 }")
        XCTAssertNil(applying("{ cisis'4 }", at: "cisis") { $0.move(events: [$1], by: .chromatic(1)) })
    }

    func testChordMovesAllMembers() {
        let src = "\\relative c' { <c e g>2 c }"
        let out = applying(src, at: "<c") { $0.move(events: [$1], by: .octave(1)) }!
        XCTAssertEqual(out, "\\relative c' { <c' e g>2 c, }")
        XCTAssertEqual(pitches(out), ["0:0:2", "2:0:2", "4:0:2", "0:0:1"])
    }

    func testDurationChangeProtectsTheInheritingNote() {
        let src = "{ c'4 d' e' f'2 }"
        let out = applying(src, at: "d'") { $0.setDuration(events: [$1], to: DurationValue(log: 3)) }!
        XCTAssertEqual(out, "{ c'4 d'8 e'4 f'2 }")
        XCTAssertEqual(durations(out), ["4", "8", "4", "2"])
        // Explicit durations are replaced in place.
        XCTAssertEqual(applying(src, at: "c'4") { $0.setDuration(events: [$1], to: DurationValue(log: 1)) },
                       "{ c'2 d'4 e' f'2 }")
    }

    func testToggleDot() {
        XCTAssertEqual(applying("{ c'4 d' }", at: "c'4") { $0.toggleDot(events: [$1]) }, "{ c'4. d'4 }")
        XCTAssertEqual(applying("{ c'4. d'8 }", at: "c'4.") { $0.toggleDot(events: [$1]) }, "{ c'4 d'8 }")
    }

    func testTogglePostEvents() {
        XCTAssertEqual(applying("{ c'4 d' }", at: "c'4") { $0.togglePostEvent("(", events: [$1]) }, "{ c'4( d' }")
        XCTAssertEqual(applying("{ c'4( d' }", at: "c'4") { $0.togglePostEvent("(", events: [$1]) }, "{ c'4 d' }")
        XCTAssertEqual(applying("{ c'4-. d' }", at: "c'4") { $0.togglePostEvent("\\fermata", events: [$1]) },
                       "{ c'4-.\\fermata d' }")
    }

    func testInsertInRelativeMode() {
        let src = "\\relative c' { c4 e f }"
        // Insert g after e: nearest g to e is above; f must stay where it was.
        let out = applying(src, at: "e") { $0.insert(step: 4, after: $1, duration: nil) }!
        XCTAssertEqual(out, "\\relative c' { c4 e g f }")
        XCTAssertEqual(pitches(out), ["0:0:1", "2:0:1", "4:0:1", "3:0:1"])
        // Inserting b changes f's reference enough to need a mark.
        let out2 = applying("\\relative c' { c4 c f }", at: "c f") { $0.insert(step: 6, after: $1, duration: nil) }!
        XCTAssertEqual(pitches(out2), ["0:0:1", "0:0:1", "6:0:0", "3:0:1"])
    }

    func testInsertWithDurationProtectsTheNext() {
        let out = applying("{ c'4 d' e' }", at: "c'4") { $0.insert(step: 1, after: $1, duration: DurationValue(log: 3)) }!
        XCTAssertEqual(out, "{ c'4 d'8 d'4 e' }")
        XCTAssertEqual(durations(out), ["4", "8", "4", "4"])
    }

    func testDeleteKeepsPitchesAndDurations() {
        let src = "\\relative c' { c4 g'8 c, d }"
        let out = applying(src, at: "g'8") { $0.delete(events: [$1]) }!
        XCTAssertEqual(pitches(out), ["0:0:1", "0:0:1", "1:0:1"])
        XCTAssertEqual(durations(out), ["4", "8", "8"])
        XCTAssertEqual(out, "\\relative c' { c4 c8 d }")
    }

    func testEditsInsideCommentsAndFormattingAreUntouched() {
        let src = "{\n  c'4 % first\n\n  d'4    e'4 %{ keep %}  f'4\n}\n"
        let out = applying(src, at: "e'4") { $0.move(events: [$1], by: .step(1)) }!
        XCTAssertEqual(out, "{\n  c'4 % first\n\n  d'4    f'4 %{ keep %}  f'4\n}\n")
    }
}

final class TextEditTests: XCTestCase {
    func testApplyMapAndInverse() {
        let text = "abcdef"
        let edits = [TextEdit(1..<2, "XY"), TextEdit.insert("!", at: 4), TextEdit(5..<6, "")]
        let out = edits.apply(to: text)
        XCTAssertEqual(out, "aXYcd!e")
        XCTAssertEqual(edits.mapOffset(0), 0)
        XCTAssertEqual(edits.mapOffset(3), 4)
        XCTAssertEqual(edits.mapOffset(4), 5)
        XCTAssertEqual(edits.inverse(original: Array(text.utf8)).apply(to: out), text)
    }

    func testOffsetConversion() {
        let s = "é𝄞c"
        XCTAssertEqual(OffsetConversion.utf16(fromUTF8: 6, in: s), 3)
        XCTAssertEqual(OffsetConversion.utf8(fromUTF16: 3, in: s), 6)
    }
}
