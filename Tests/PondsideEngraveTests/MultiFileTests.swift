import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// M2.1: scores split across `\include`d files, as real projects (and
/// musicxml2ly output) are.
final class MultiFileTests: XCTestCase {
    static var multi: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scores/multi")
    }

    func testGraphResolvesIncludesInOrder() {
        let graph = SourceGraph.load(root: Self.multi.appendingPathComponent("root.ly"))
        XCTAssertEqual(graph.files.map(\.url.lastPathComponent), ["root.ly", "defs.ily", "flute.ily", "graphics.ily"])
        XCTAssertEqual(graph.file(Self.multi.appendingPathComponent("flute.ily"))?.includedFrom?.lastPathComponent, "root.ly")
        XCTAssertTrue(graph.unresolved.isEmpty)
    }

    /// `\language "english"` in defs.ily applies to flute.ily, included later.
    func testLanguageFlowsAcrossIncludes() throws {
        let graph = SourceGraph.load(root: Self.multi.appendingPathComponent("root.ly"))
        let flute = try XCTUnwrap(graph.file(Self.multi.appendingPathComponent("flute.ily")))
        XCTAssertEqual(flute.entryLanguage, .english)
        let pitches = flute.tree.notes.filter { $0.role == .event }.map { "\($0.absolute.step):\($0.absolute.alteration)" }
        // b cs d e | fs g a | b — cs and fs are sharps in English.
        XCTAssertEqual(pitches, ["6:0", "0:2", "1:0", "2:0", "3:2", "4:0", "5:0", "6:0"])
        XCTAssertEqual(graph.root.tree.finalLanguage, .english)
    }

    func testOverridesTakePrecedence() {
        let flute = Self.multi.appendingPathComponent("flute.ily")
        let graph = SourceGraph.load(root: Self.multi.appendingPathComponent("root.ly"),
                                     overrides: [flute: "flute = { c'1 }"])
        XCTAssertEqual(graph.file(flute)?.tree.events.count, 1)
    }

    func testResolveOrder() {
        let root = URL(fileURLWithPath: "/p/score.ly")
        let includer = URL(fileURLWithPath: "/p/parts/flute.ily")
        let present: Set<String> = ["/p/parts/common.ily", "/p/common.ily", "/p/defs.ily", "/lib/x.ily"]
        let exists: (URL) -> Bool = { present.contains($0.path) }
        XCTAssertEqual(SourceGraph.resolve("common.ily", from: includer, root: root, exists: exists)?.path, "/p/parts/common.ily")
        XCTAssertEqual(SourceGraph.resolve("defs.ily", from: includer, root: root, exists: exists)?.path, "/p/defs.ily")
        XCTAssertEqual(SourceGraph.resolve("x.ily", from: includer, root: root, searchPaths: [URL(fileURLWithPath: "/lib")], exists: exists)?.path, "/lib/x.ily")
        XCTAssertNil(SourceGraph.resolve("english.ly", from: includer, root: root, exists: exists))
    }

    func testCanvasArgumentsCarrySessionSettingsButExportNever() {
        let src = URL(fileURLWithPath: "/tmp/s.ly"), out = URL(fileURLWithPath: "/tmp/o/s")
        let settings = URL(fileURLWithPath: "/tmp/o/pondside-session.ily")
        XCTAssertTrue(LilyPondEngraver.arguments(for: .canvas, source: src, outputBase: out, sessionSettings: settings)
            .contains("-dinclude-settings=/tmp/o/pondside-session.ily"))
        for f in ExportFormat.allCases {
            XCTAssertFalse(LilyPondEngraver.arguments(for: .export(f), source: src, outputBase: out, sessionSettings: settings)
                .contains { $0.hasPrefix("-dinclude-settings") })
        }
    }

    /// flute.ily starts with `\pointAndClickOff`; the canvas compile must
    /// still link its notes, without touching the file.
    func testPointAndClickOffIsNeutralizedForTheCanvas() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let root = Self.multi.appendingPathComponent("root.ly")
        let fluteURL = Self.multi.appendingPathComponent("flute.ily")
        let before = try Data(contentsOf: fluteURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-multi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await LilyPondEngraver(installation: lily).engrave(root, purpose: .canvas, outputDirectory: dir)
        XCTAssertTrue(result.succeeded, result.log)
        let page = EngravedPage(svg: try Data(contentsOf: result.outputFiles[0]))
        let linkedFiles = Set(page.graphics.compactMap { $0.link.map { URL(fileURLWithPath: $0.path).lastPathComponent } })
        XCTAssertEqual(linkedFiles, ["flute.ily"])
        XCTAssertGreaterThanOrEqual(page.graphics.filter { $0.link != nil }.count, 8)
        XCTAssertEqual(try Data(contentsOf: fluteURL), before, "the user's file must not change")
    }
}
