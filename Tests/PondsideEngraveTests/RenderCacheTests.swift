import Foundation
import XCTest
@testable import PondsideEngrave

final class RenderCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ text: String, pages: Int = 2) -> RenderCache.Entry {
        RenderCache.Entry(pages: (1...pages).map { Data("<svg>\(text) \($0)</svg>".utf8) },
                          snapshots: ["/music/score.ly": text], lilypondVersion: "2.24.3",
                          date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testStoreThenLoadRoundTrips() throws {
        let cache = RenderCache(root: root)
        let score = URL(fileURLWithPath: "/music/score.ly")
        XCTAssertNil(cache.load(for: score))
        try cache.store(entry("c'4"), for: score)
        XCTAssertEqual(cache.load(for: score), entry("c'4"))
    }

    func testStoreReplacesTheWholeEntry() throws {
        let cache = RenderCache(root: root)
        let score = URL(fileURLWithPath: "/music/score.ly")
        try cache.store(entry("c'4", pages: 3), for: score)
        try cache.store(entry("d'4", pages: 1), for: score)
        XCTAssertEqual(cache.load(for: score), entry("d'4", pages: 1))
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory(for: score).path)
        XCTAssertEqual(Set(files), ["manifest.json", "page-1.svg"])
        // Only the entry itself is left: nothing staged or retired.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testScoresKeepSeparateEntries() throws {
        let cache = RenderCache(root: root)
        let a = URL(fileURLWithPath: "/music/a.ly"), b = URL(fileURLWithPath: "/music/b.ly")
        try cache.store(entry("a"), for: a)
        try cache.store(entry("b"), for: b)
        XCTAssertEqual(cache.load(for: a)?.snapshots.values.first, "a")
        XCTAssertEqual(cache.load(for: b)?.snapshots.values.first, "b")
    }

    func testDamagedEntriesAreMisses() throws {
        let cache = RenderCache(root: root)
        let score = URL(fileURLWithPath: "/music/score.ly")
        try cache.store(entry("c'4"), for: score)
        let folder = cache.directory(for: score)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("page-2.svg"))
        XCTAssertNil(cache.load(for: score))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertNil(cache.load(for: score))
    }

    func testPruneKeepsTheMostRecent() throws {
        let cache = RenderCache(root: root)
        let scores = (0..<4).map { URL(fileURLWithPath: "/music/\($0).ly") }
        for (i, score) in scores.enumerated() {
            try cache.store(entry("\(i)"), for: score)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))],
                                                  ofItemAtPath: cache.directory(for: score).path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".staging-left-over"),
                                                withIntermediateDirectories: false)
        cache.prune(entries: 2)
        XCTAssertNil(cache.load(for: scores[0]))
        XCTAssertNil(cache.load(for: scores[1]))
        XCTAssertNotNil(cache.load(for: scores[2]))
        XCTAssertNotNil(cache.load(for: scores[3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".staging-left-over").path))
    }
}
