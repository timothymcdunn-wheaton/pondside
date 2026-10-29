import Foundation
import XCTest
@testable import PondsideEngrave

final class ShadowHistoryTests: XCTestCase {
    func testCheckpointsStayOutOfTheProject() async throws {
        guard ShadowHistory.findGit() != nil else { throw XCTSkip("git not installed") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-history-\(UUID().uuidString)")
        let project = base.appendingPathComponent("piece"), store = base.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let score = project.appendingPathComponent("score.ly")
        try "{ c'1 }\n".write(to: score, atomically: true, encoding: .utf8)
        let history = ShadowHistory(score: score, root: store)

        let first = try await history.checkpoint([score])
        XCTAssertTrue(first)
        let unchanged = try await history.checkpoint([score])
        XCTAssertFalse(unchanged, "nothing changed, no checkpoint")
        try "{ d'1 }\n".write(to: score, atomically: true, encoding: .utf8)
        let second = try await history.checkpoint([score], message: "edit")
        XCTAssertTrue(second)

        let checkpoints = try await history.checkpoints()
        XCTAssertEqual(checkpoints.count, 2)
        let old = try await history.text(of: score, at: checkpoints[1].revision)
        XCTAssertEqual(old, "{ c'1 }\n")
        // The project folder holds only the score: no .git, no .pondside.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["score.ly"])
    }
}
