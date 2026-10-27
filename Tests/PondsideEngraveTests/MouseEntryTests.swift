import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

final class MouseEntryTests: XCTestCase {
    func testFindsTheStaffInAFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/etude.svg")
        let page = EngravedPage(svg: try Data(contentsOf: url))
        let staves = page.staves
        XCTAssertEqual(staves.count, 1)
        let s = try XCTUnwrap(staves.first)
        XCTAssertEqual(s.lineYs.count, 5)
        XCTAssertGreaterThan(s.space, 0)
        XCTAssertEqual(s.position(ofY: s.bottom), 0)
        XCTAssertEqual(s.position(ofY: s.top), 8)
        XCTAssertEqual(s.position(ofY: s.y(ofPosition: -3)), -3)
    }

    func testStaffDetectionNeedsFiveEvenLines() {
        func line(_ y: Double, _ x1: Double = 0, _ x2: Double = 50) -> Graphic {
            let p = VectorPath([.move(Point(x1, y)), .line(Point(x2, y))])
            return Graphic(content: .path(p, fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                           bounds: Rect(x: x1, y: y - 0.05, width: x2 - x1, height: 0.1), link: nil)
        }
        // Two staves of one system, plus a stray text-spanner line.
        let lines = (0..<5).map { line(10 + Double($0)) } + (0..<5).map { line(22 + Double($0)) } + [line(5, 3, 20)]
        let staves = EngravedPage.staves(in: lines)
        XCTAssertEqual(staves.map(\.top), [10, 22])
        // Four lines are not a staff.
        XCTAssertTrue(EngravedPage.staves(in: (0..<4).map { line(Double($0)) }).isEmpty)
    }

    func testCalibratesFromTheNearestNote() {
        let staff = Staff(lineYs: [10, 11, 12, 13, 14], minX: 0, maxX: 100)
        // e' on the bottom line (treble clef), at x 20; a rest at x 30.
        let anchors = [
            MouseEntry.Anchor(bounds: Rect(x: 19.5, y: 13.5, width: 1.2, height: 1), pitch: Pitch(step: 2, octave: 1), ref: 0),
            MouseEntry.Anchor(bounds: Rect(x: 30, y: 11, width: 1, height: 2), pitch: nil, ref: 1),
        ]
        // Top line, right of the rest: f'' after the rest.
        let t = try? MouseEntry.target(click: Point(35, 10), staff: staff, anchors: anchors).get()
        XCTAssertEqual(t?.step, 3)
        XCTAssertEqual(t?.octave, 2)
        XCTAssertEqual(t?.after, 1)
        // Below the staff: c' on the first ledger line.
        XCTAssertEqual(try? MouseEntry.target(click: Point(25, 15), staff: staff, anchors: anchors).get().diatonicIndex, 7)
        XCTAssertEqual(MouseEntry.target(click: Point(5, 12), staff: staff, anchors: anchors), .failure(.nothingBefore))
        XCTAssertEqual(MouseEntry.target(click: Point(35, 12), staff: staff, anchors: [anchors[1]]), .failure(.uncalibrated))
    }

    /// End to end: engrave a grand staff, find both staves, and read
    /// pitches off clicks in treble and bass without knowing the clefs.
    func testClicksMeanPitchesOnARealScore() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let source = """
        \\version "2.24.0"
        \\new PianoStaff <<
          \\new Staff \\relative c'' { c4 d e f | g1 }
          \\new Staff { \\clef bass c4 d e r | f1 }
        >>

        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mouse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("grand.ly")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas, outputDirectory: dir)
        XCTAssertTrue(result.succeeded, result.log)
        let page = EngravedPage(svg: try Data(contentsOf: result.outputFiles[0]))

        let staves = page.staves
        XCTAssertEqual(staves.count, 2)
        guard staves.count == 2 else { return }
        let tree = SyntaxTree(source)
        let text = SourceText(source)
        func anchors(_ s: Staff) -> [MouseEntry.Anchor] {
            MouseEntry.anchors(on: s, page: page, tree: tree, linkedFrom: { _ in true }) { p in
                text.index(of: p).map { source.utf8.distance(from: source.startIndex, to: $0) }
            }
        }
        let treble = anchors(staves[0]), bass = anchors(staves[1])
        XCTAssertEqual(treble.count, 5)
        XCTAssertEqual(bass.count, 5)
        XCTAssertEqual(bass.filter { $0.pitch == nil }.count, 1)

        func click(_ staff: Staff, _ anchors: [MouseEntry.Anchor], between i: Int, position: Int) throws -> MouseEntry.Target {
            let sorted = anchors.sorted { $0.bounds.minX < $1.bounds.minX }
            let x = (sorted[i].bounds.maxX + sorted[i + 1].bounds.minX) / 2
            return try MouseEntry.target(click: Point(x, staff.y(ofPosition: position)), staff: staff, anchors: anchors).get()
        }
        // Treble bottom line is e', top line f''.
        XCTAssertEqual(try click(staves[0], treble, between: 2, position: 0).diatonicIndex, Pitch(step: 2, octave: 1).diatonicIndex)
        XCTAssertEqual(try click(staves[0], treble, between: 0, position: 8).diatonicIndex, Pitch(step: 3, octave: 2).diatonicIndex)
        // Bass top line is a, bottom line g,; middle line d.
        XCTAssertEqual(try click(staves[1], bass, between: 1, position: 8).diatonicIndex, Pitch(step: 5, octave: 0).diatonicIndex)
        XCTAssertEqual(try click(staves[1], bass, between: 3, position: 0).diatonicIndex, Pitch(step: 4, octave: -1).diatonicIndex)
        let mid = try click(staves[1], bass, between: 0, position: 4)
        XCTAssertEqual(mid.diatonicIndex, Pitch(step: 1, octave: 0).diatonicIndex)
        // Inserted after the c (the first event of the bass staff).
        XCTAssertEqual(tree.string(tree.events[mid.after].range), "c4")
    }
}
