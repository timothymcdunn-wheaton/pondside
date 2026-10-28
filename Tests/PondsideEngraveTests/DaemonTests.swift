import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// M4: the warm daemon gives the same engraving as a cold compile, faster.
final class DaemonTests: XCTestCase {
    static var multi: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scores/multi")
    }

    func lilypond() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return lily
    }

    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-daemon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func links(_ result: EngraveResult) throws -> Int {
        result.pages().reduce(0) { n, page in n + page.graphics.filter { $0.link != nil }.count }
    }

    func testWarmCompilesMatchColdOnesAndAreFaster() async throws {
        let lily = try await lilypond()
        let dir = try temp()
        let root = Self.multi.appendingPathComponent("root.ly")
        let cold = try await LilyPondEngraver(installation: lily).engrave(root, purpose: .canvas, outputDirectory: dir.appendingPathComponent("cold"))
        XCTAssertTrue(cold.succeeded, cold.log)

        let daemon = LilyPondDaemon(installation: lily)
        var warm: [Duration] = []
        for i in 0..<4 {
            let r = try await daemon.engrave(root, outputDirectory: dir.appendingPathComponent("warm\(i)"))
            XCTAssertTrue(r.succeeded, r.log)
            XCTAssertEqual(try links(r), try links(cold), "same point-and-click links as a cold compile, \\pointAndClickOff and all")
            XCTAssertEqual(r.outputFiles.map(\.lastPathComponent), cold.outputFiles.map(\.lastPathComponent))
            warm.append(r.duration)
        }
        await daemon.stop()
        let ms = { (d: Duration) in Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        let steady = warm.dropFirst().map(ms).sorted()[1]
        print("Pondside benchmark: cold \(ms(cold.duration)) ms, warm median \(steady) ms (multi-file fixture)")
        XCTAssertLessThan(steady, ms(cold.duration) / 2)
    }

    func testErrorsDoNotKillTheDaemon() async throws {
        let lily = try await lilypond()
        let dir = try temp()
        let bad = dir.appendingPathComponent("bad.ly"), good = dir.appendingPathComponent("good.ly")
        try "\\version \"2.24.0\"\n{ c'4 \\nosuch d' }\n".write(to: bad, atomically: true, encoding: .utf8)
        try "\\version \"2.24.0\"\n#(display \"chatter\")\n{ c'4 d' }\n".write(to: good, atomically: true, encoding: .utf8)
        let daemon = LilyPondDaemon(installation: lily)
        let r1 = try await daemon.engrave(bad, outputDirectory: dir.appendingPathComponent("o1"))
        XCTAssertFalse(r1.errors.isEmpty, r1.log)
        XCTAssertEqual(r1.errors.first?.line, 2)
        let r2 = try await daemon.engrave(good, outputDirectory: dir.appendingPathComponent("o2"))
        XCTAssertTrue(r2.succeeded, r2.log)
        XCTAssertTrue(r2.errors.isEmpty, r2.log)
        XCTAssertTrue(r2.log.contains("chatter"), "stdout is drained and kept with the job's log")
        // The score's folder gets no output files.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".svg") }, [])
        await daemon.stop()
    }

    func testAStoppedDaemonRestartsAndTheEngraverFallsBack() async throws {
        let lily = try await lilypond()
        let dir = try temp()
        let root = Self.multi.appendingPathComponent("root.ly")
        let daemon = LilyPondDaemon(installation: lily)
        _ = try await daemon.engrave(root, outputDirectory: dir.appendingPathComponent("a"))
        await daemon.stop()
        let again = try await daemon.engrave(root, outputDirectory: dir.appendingPathComponent("b"))
        XCTAssertTrue(again.succeeded, again.log)
        let viaEngraver = try await LilyPondEngraver(installation: lily, daemon: daemon)
            .engrave(root, purpose: .canvas, outputDirectory: dir.appendingPathComponent("c"))
        XCTAssertTrue(viaEngraver.succeeded)
        await daemon.stop()
    }
}
