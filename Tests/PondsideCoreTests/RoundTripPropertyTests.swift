import Foundation
import XCTest
@testable import PondsideCore

/// The M2 acceptance tests: thousands of random graphical edits must never
/// corrupt formatting, and must never change any note they don't target.
///
/// Each edit is checked for:
/// 1. **Locality** — every replaced byte lies in the target event, in another
///    note's octave marks (relative compensation), or is a pure insertion at
///    an event's duration slot (duration compensation). Comments, whitespace
///    and everything else are byte-identical.
/// 2. **Semantics** — re-parsing, every non-target note keeps its absolute
///    pitch and every non-target event keeps its effective duration.
/// 3. **Losslessness** — the tree reproduces the new text exactly.
/// 4. **Reversibility** — applying the inverse edits in reverse order restores
///    the original file byte for byte.
final class RoundTripPropertyTests: XCTestCase {
    /// Tests/Scores, located from this source file so every test target can
    /// share the same real-world scores.
    static func fixtures() throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scores")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".ly") }.sorted()
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testOneThousandEditsPerFixture() throws {
        for (name, text) in try Self.fixtures() {
            var fuzzer = EditFuzzer(seed: UInt64(truncatingIfNeeded: name.hashValueStable))
            let report = fuzzer.run(on: text, edits: 1000)
            XCTAssertEqual(report.failures, [], "\(name)")
            XCTAssertGreaterThan(report.applied, 800, "\(name): too few edits applied")
            XCTAssertTrue(report.restored, "\(name): inverse edits did not restore the original")
        }
    }

    /// LilyPond's regression suite and snippets. CI downloads them and sets
    /// PONDSIDE_CORPUS; locally the test skips.
    func testCorpus() throws {
        guard let root = ProcessInfo.processInfo.environment["PONDSIDE_CORPUS"] else {
            throw XCTSkip("set PONDSIDE_CORPUS to a directory of .ly files")
        }
        let files = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".ly") || $0.hasSuffix(".ily") }.sorted() ?? []
        XCTAssertGreaterThan(files.count, 100, "corpus looks empty")

        var withIssues: [String] = []
        var editFailures: [String] = []
        var totalEdits = 0
        var notesSeen = 0
        for (k, file) in files.enumerated() {
            guard let data = FileManager.default.contents(atPath: root + "/" + file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let tree = SyntaxTree(text)
            XCTAssertEqual(tree.reconstructed, text, "lossless: \(file)")
            notesSeen += tree.notes.count
            if !tree.issues.isEmpty { withIssues.append(file) }
            var fuzzer = EditFuzzer(seed: UInt64(k) &* 0x9E37_79B9 &+ 17)
            let report = fuzzer.run(on: text, edits: 20)
            totalEdits += report.applied
            if !report.failures.isEmpty || !report.restored {
                editFailures.append("\(file): \(report.failures.prefix(3)) restored=\(report.restored)")
            }
        }
        let issueRate = Double(withIssues.count) / Double(max(1, files.count))
        print("corpus: \(files.count) files, \(notesSeen) notes, \(totalEdits) edits, "
              + "\(withIssues.count) files with recovered syntax (\(String(format: "%.1f", issueRate * 100))%)")
        for f in withIssues.prefix(40) { print("  recovered: \(f)") }
        XCTAssertEqual(editFailures, [])
        // Some regression files test error handling on purpose; most must
        // parse without recovery.
        XCTAssertLessThan(issueRate, 0.03)
    }
}

extension String {
    /// A hash that is stable across runs (Swift's hashValue is seeded).
    var hashValueStable: Int {
        Int(truncatingIfNeeded: ContentHash(self).value)
    }
}

/// Random graphical edits with invariant checking.
struct EditFuzzer {
    var rng: SplitMix64

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    struct Report {
        var applied = 0
        var failures: [String] = []
        var restored = false
    }

    private mutating func pick<T>(_ xs: [T]) -> T? {
        xs.isEmpty ? nil : xs[Int(rng.next() % UInt64(xs.count))]
    }

    mutating func run(on original: String, edits count: Int) -> Report {
        var report = Report()
        var text = original
        var history: [(edits: [TextEdit], before: [UInt8])] = []
        for _ in 0..<count {
            let tree = SyntaxTree(text)
            guard let candidate = randomEdit(tree) else { continue }
            let (edit, check) = candidate
            if edit.isEmpty { continue }
            if let problem = validate(edit, check: check, in: tree) {
                report.failures.append(problem)
                if report.failures.count > 5 { break }
                continue
            }
            history.append((edit.edits, tree.bytes))
            text = edit.edits.apply(to: text)
            report.applied += 1
        }
        // Undo everything in reverse.
        var bytes = Array(text.utf8)
        for step in history.reversed() {
            bytes = step.edits.inverse(original: step.before).apply(to: bytes)
        }
        report.restored = bytes == Array(original.utf8)
        return report
    }

    enum Check {
        case pitch(targets: Set<Int>)                // note indices whose pitch may change
        case duration(targets: Set<Int>)             // event indices whose duration may change
        case insert(after: Int, isRest: Bool)
        case delete(events: Set<Int>)
        case postEvent(targets: Set<Int>)
    }

    mutating func randomEdit(_ tree: SyntaxTree) -> (ScoreEdit, Check)? {
        let editor = ScoreEditor(tree)
        let pitched = tree.events.indices.filter { tree.events[$0].isPitched }
        let entry = tree.events.indices.filter { tree.events[$0].acceptsNoteEntry }
        let all = Array(tree.events.indices)
        switch rng.next() % 8 {
        case 0, 1:
            guard let e = pick(pitched) else { return nil }
            let moves: [ScoreEditor.PitchMove] = [.step(1), .step(-1), .step(2), .octave(1), .octave(-1), .chromatic(1), .chromatic(-1)]
            let move = pick(moves)!
            guard let edit = editor.move(events: [e], by: move) else { return nil }
            return (edit, .pitch(targets: Set(tree.events[e].notes)))
        case 2:
            guard let e = pick(all) else { return nil }
            let d = DurationValue(log: Int(rng.next() % 6), dots: Int(rng.next() % 2))
            guard let edit = editor.setDuration(events: [e], to: d) else { return nil }
            return (edit, .duration(targets: [e]))
        case 3:
            guard let e = pick(all), let edit = editor.toggleDot(events: [e]) else { return nil }
            return (edit, .duration(targets: [e]))
        case 4:
            guard let e = pick(entry) else { return nil }
            let marks = ["(", ")", "~", "-.", "->", "\\fermata", "\\p", "["]
            guard let edit = editor.togglePostEvent(pick(marks)!, events: [e]) else { return nil }
            return (edit, .postEvent(targets: [e]))
        case 5, 6:
            guard let e = pick(entry) else { return nil }
            let isRest = rng.next() % 5 == 0
            let step: Int? = isRest ? nil : Int(rng.next() % 7)
            let duration: DurationValue? = rng.next() % 2 == 0 ? nil : DurationValue(log: Int(rng.next() % 5))
            return (editor.insert(step: step, after: e, duration: duration), .insert(after: e, isRest: isRest))
        default:
            guard let e = pick(entry), let edit = editor.delete(events: [e]) else { return nil }
            return (edit, .delete(events: [e]))
        }
    }

    /// Returns a description of the first violated invariant, or nil.
    func validate(_ edit: ScoreEdit, check: Check, in old: SyntaxTree) -> String? {
        let edits = edit.edits
        guard edits.isNonOverlapping else { return "overlapping edits \(edits)" }

        // 1. Locality.
        var targetEvents = Set<Int>()
        switch check {
        case .pitch(let notes): targetEvents = Set(notes.compactMap { old.notes[$0].event })
        case .duration(let e), .postEvent(let e), .delete(let e): targetEvents = e
        case .insert(let e, _): targetEvents = [e]
        }
        let spelled = Set(old.notes.map(\.spelledRange)).union(old.notes.compactMap(\.octaveCheck))
        let durationSlots = Set(old.events.map(\.durationInsertion))
        for e in edits {
            let inTarget = targetEvents.contains { t in
                let r = old.events[t].range
                let widened = deletionWindow(r, old.bytes)
                return (e.range.lowerBound >= widened.lowerBound && e.range.upperBound <= widened.upperBound)
            }
            let isMarks = spelled.contains(e.range)
            let isSlot = e.range.isEmpty && durationSlots.contains(e.range.lowerBound)
            if !(inTarget || isMarks || isSlot) {
                return "non-local edit \(e) for \(check) near \"\(old.string(max(0, e.range.lowerBound - 10)..<min(old.bytes.count, e.range.upperBound + 10)))\""
            }
        }

        // 3. Losslessness.
        let newText = edits.apply(to: old.text)
        let new = SyntaxTree(newText)
        guard new.reconstructed == newText else { return "not lossless after \(edits)" }

        // 2. Semantics.
        let oldEventNotes = old.notes.indices.filter { old.notes[$0].role == .event }
        let newEventNotes = new.notes.indices.filter { new.notes[$0].role == .event }
        var skipOldNotes = Set<Int>(), skipNewNotes = Set<Int>()
        var skipOldEvents = Set<Int>(), skipNewEvents = Set<Int>()
        switch check {
        case .pitch(let t):
            skipOldNotes = t
            skipNewNotes = t
        case .duration(let t):
            skipOldEvents = t
            skipNewEvents = t
        case .postEvent:
            break
        case .insert(let e, let isRest):
            skipNewEvents = [e + 1]
            if !isRest, let firstNew = new.events[safe: e + 1]?.notes.first { skipNewNotes = [firstNew] }
        case .delete(let t):
            skipOldEvents = t
            skipOldNotes = Set(t.flatMap { old.events[$0].notes })
        }
        let oldPitches = oldEventNotes.filter { !skipOldNotes.contains($0) }.map { old.notes[$0].absolute }
        let newPitches = newEventNotes.filter { !skipNewNotes.contains($0) }.map { new.notes[$0].absolute }
        if oldPitches != newPitches {
            let i = zip(oldPitches, newPitches).firstIndex { $0 != $1 } ?? min(oldPitches.count, newPitches.count)
            return "pitches changed for \(check) at note #\(i): \(oldPitches[safe: i].map(\.description) ?? "-") → \(newPitches[safe: i].map(\.description) ?? "-"); edits \(edits)"
        }
        let oldDurations = old.events.indices.filter { !skipOldEvents.contains($0) }.map { old.events[$0].effectiveDuration }
        let newDurations = new.events.indices.filter { !skipNewEvents.contains($0) }.map { new.events[$0].effectiveDuration }
        if oldDurations != newDurations {
            let i = zip(oldDurations, newDurations).firstIndex { $0 != $1 } ?? min(oldDurations.count, newDurations.count)
            return "durations changed for \(check) at event #\(i); edits \(edits)"
        }
        return nil
    }

    private func deletionWindow(_ r: Range<Int>, _ b: [UInt8]) -> Range<Int> {
        var s = r.lowerBound
        while s > 0, b[s - 1] == 0x20 || b[s - 1] == 0x09 { s -= 1 }
        var e = r.upperBound
        while e < b.count, b[e] == 0x20 || b[e] == 0x09 { e += 1 }
        return s..<e
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
