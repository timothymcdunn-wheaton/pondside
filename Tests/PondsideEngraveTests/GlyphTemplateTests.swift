import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

final class GlyphTemplateTests: XCTestCase {
    private func path(_ r: Rect, fill: RGBA? = .black, stroke: RGBA? = nil) -> Graphic {
        Graphic(content: .path(VectorPath.rect(r), fill: fill, stroke: stroke, style: StrokeStyle(width: 0.1)),
                bounds: r, link: nil)
    }

    func testKeepsTheNoteheadAndStemButNotTheAccidentalLedgerOrSlur() throws {
        let head = path(Rect(x: 10, y: 10, width: 1.3, height: 1))
        let stem = path(Rect(x: 11.2, y: 6, width: 0.12, height: 4))
        let accidental = path(Rect(x: 8.5, y: 9.5, width: 0.6, height: 1.5))
        let ledger = path(Rect(x: 9, y: 15, width: 3.3, height: 0.1))
        let slur = path(Rect(x: 8, y: 8, width: 6, height: 2))

        let glyph = try XCTUnwrap(EngravedPage.noteGlyph(
            among: [head, stem, accidental, ledger, slur], space: 1))
        XCTAssertEqual(glyph.head, head.bounds)
        XCTAssertEqual(glyph.graphics, [head, stem])
        XCTAssertEqual(glyph.bounds, head.bounds.union(stem.bounds))
    }

    func testAChordOnlyMovesTheChosenNotehead() throws {
        let low = path(Rect(x: 10, y: 11, width: 1.3, height: 1))
        let high = path(Rect(x: 10, y: 8, width: 1.3, height: 1))
        let stem = path(Rect(x: 11.2, y: 6, width: 0.12, height: 6))

        let glyph = try XCTUnwrap(EngravedPage.noteGlyph(among: [low, high, stem], space: 1))
        XCTAssertEqual(glyph.graphics.count, 1)
        XCTAssertTrue(glyph.graphics == [low] || glyph.graphics == [high])
    }

    func testTranslationMovesTheHeadAndEveryCompanion() throws {
        let head = path(Rect(x: 10, y: 10, width: 1.3, height: 1))
        let stem = path(Rect(x: 11.2, y: 6, width: 0.12, height: 4))
        let glyph = try XCTUnwrap(EngravedPage.noteGlyph(among: [head, stem], space: 1))

        let moved = glyph.translated(by: Point(2, -3))
        XCTAssertEqual(moved.head, Rect(x: 12, y: 7, width: 1.3, height: 1))
        XCTAssertEqual(moved.graphics.map(\.bounds), [
            Rect(x: 12, y: 7, width: 1.3, height: 1),
            Rect(x: 13.2, y: 3, width: 0.12, height: 4),
        ])
        XCTAssertEqual(moved.graphics[0].content, head.translated(by: Point(2, -3)).content)
    }

    func testPlacingTheHeadCentresIt() throws {
        let head = path(Rect(x: 10, y: 10, width: 2, height: 1))
        let glyph = try XCTUnwrap(EngravedPage.noteGlyph(among: [head], space: 1))
        let placed = glyph.placingHead(at: Point(30, 20))
        XCTAssertEqual(placed.head.midX, 30)
        XCTAssertEqual(placed.head.midY, 20)
    }

    func testDeletionTakesTheUnlinkedStemButNotTheNeighbour() {
        let head = path(Rect(x: 10, y: 10, width: 1.3, height: 1))
        let stem = path(Rect(x: 11.2, y: 6, width: 0.13, height: 4))
        let neighbourHead = path(Rect(x: 13.5, y: 10, width: 1.3, height: 1))
        let neighbourStem = path(Rect(x: 13.6, y: 6, width: 0.13, height: 4))

        let removed = EngravedPage.removalSet(
            for: [head], among: [head, stem, neighbourHead, neighbourStem], space: 1)
        XCTAssertEqual(removed, [head, stem])
    }

    func testFixtureDeletionIncludesTheStem() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("etude.svg")))
        let position = SourcePosition(line: 5, character: 20)
        let linked = page.linkedGraphics(at: position)
        let staff = try XCTUnwrap(page.staff(at: Point(linked[0].bounds.midX, linked[0].bounds.midY)))
        let removed = EngravedPage.removalSet(for: linked, among: page.graphics, space: staff.space)
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(removed.contains { g in
            g.bounds.width < 0.3 * staff.space && g.bounds.height > 1.5 * staff.space
        })
    }

    func testReadsARealNoteFromTheFixture() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("etude.svg")))
        let position = SourcePosition(line: 5, character: 20)
        let graphics = page.linkedGraphics(at: position)
        XCTAssertFalse(graphics.isEmpty)
        let staff = try XCTUnwrap(page.staff(at: Point(graphics[0].bounds.midX, graphics[0].bounds.midY)))
        let glyph = try XCTUnwrap(page.noteGlyph(at: position))
        XCTAssertEqual(glyph.space, staff.space, accuracy: 1e-9)
        XCTAssertTrue(glyph.graphics.contains { $0.bounds == glyph.head })
        XCTAssertEqual(page.noteGlyph(at: position, among: [staff]), glyph)
    }
}
