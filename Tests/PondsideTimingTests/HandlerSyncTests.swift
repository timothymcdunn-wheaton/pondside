import Foundation
import XCTest
@testable import PondsideTiming

final class HandlerSyncTests: XCTestCase {
    func sheet(_ cues: [(String, Rational)]) -> CueSheet {
        var text = "PONDSIDE-TIMING\t0\t1\t@0\tmeter\t4/4\nPONDSIDE-TIMING\t0\t1\t@0\ttempo\t60\n"
        for (name, m) in cues {
            let bar = Int((m.doubleValue).rounded(.down)) + 1
            let pos = m - Rational(bar - 1)
            text += "PONDSIDE-TIMING\t\(m)\t\(bar)\t@\(pos)\ttext\tcue \(name)\n"
        }
        return CueSheet(log: TimingLog(parsing: text, prefix: "PONDSIDE-TIMING\t"), score: "piece.ly")
    }

    func testStarterHasAStubPerCue() {
        let s = HandlerSync.starter(sheet([("1", Rational(0)), ("2", Rational(1))]), projectPath: "~/scores/piece")
        XCTAssertTrue(s.contains("p = Pondside(\"~/scores/piece\");"))
        XCTAssertTrue(s.contains("// @pondside cue cue-1 · bar 1 beat 1 · 0.000 s\np.on(\\cue1, { |cue|"))
        XCTAssertTrue(s.contains("// @pondside cue cue-2 · bar 2 beat 1 · 4.000 s"))
        XCTAssertEqual(HandlerSync.blocks(s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).count, 2)
    }

    /// The law: Pondside never modifies code inside a handler body.
    func testBodiesSurviveEveryChange() {
        let v1 = sheet([("1", Rational(0)), ("2", Rational(1))])
        var file = HandlerSync.starter(v1, projectPath: "p")
        let mine = "\t~verb.set(\\mix, 0.4);  // composer's code"
        file = file.replacingOccurrences(of: "\t// cue 2 at moment 1\n", with: "\t// cue 2 at moment 1\n\(mine)\n")

        // Cue 2 moves, cue 3 appears between 1 and 2.
        let v2 = sheet([("1", Rational(0)), ("3", Rational(1, 2)), ("2", Rational(3, 2))])
        let (moved, r2) = HandlerSync.sync(file, with: v2)
        XCTAssertEqual(r2.added, ["cue-3"])
        XCTAssertEqual(r2.moved, ["cue-2"])
        XCTAssertTrue(moved.contains(mine))
        XCTAssertTrue(moved.contains("// @pondside cue cue-2 · bar 2 beat 3 · 6.000 s"))
        let order = HandlerSync.blocks(moved.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).map(\.id)
        XCTAssertEqual(order, ["cue-1", "cue-3", "cue-2"])

        // Cue 2 leaves the score: commented out, not deleted.
        let v3 = sheet([("1", Rational(0)), ("3", Rational(1, 2))])
        let (orphaned, r3) = HandlerSync.sync(moved, with: v3)
        XCTAssertEqual(r3.orphaned, ["cue-2"])
        XCTAssertTrue(orphaned.contains("//~ " + mine))
        XCTAssertFalse(orphaned.contains("\n" + mine))

        // ...and comes back exactly.
        let (restored, r4) = HandlerSync.sync(orphaned, with: v2)
        XCTAssertEqual(r4.restored, ["cue-2"])
        XCTAssertEqual(restored, moved)

        // Syncing twice changes nothing.
        let (again, r5) = HandlerSync.sync(restored, with: v2)
        XCTAssertEqual(again, restored)
        XCTAssertEqual(r5, HandlerSync.Report())
    }

    func testCodeOutsideBlocksIsUntouched() {
        let file = "s.boot;\n// my notes\n~x = 1;\n"
        let (out, report) = HandlerSync.sync(file, with: sheet([("A", Rational(0))]))
        XCTAssertTrue(out.hasPrefix("s.boot;\n// my notes\n~x = 1;\n"))
        XCTAssertEqual(report.added, ["cue-A"])
        XCTAssertTrue(out.contains("p.on(\\a, { |cue|"))
    }
}
