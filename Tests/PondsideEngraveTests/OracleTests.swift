import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// Pondside's static model of the music — absolute pitches through
/// `\relative` chains, inherited durations — checked against LilyPond's own
/// interpretation of every note, before and after random graphical edits.
///
/// Together with the Core property tests (an edit never changes a
/// non-target note *in the model*), agreement here before and after each
/// edit means an edit never changes a non-target note *in LilyPond*.
final class OracleTests: XCTestCase {
    static var scoresDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scores")
    }

    func installation() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let i = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return i
    }

    func scores() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: Self.scoresDirectory.path)
            .filter { $0.hasSuffix(".ly") }.sorted()
            .map { Self.scoresDirectory.appendingPathComponent($0) }
    }

    /// Returns mismatches between the model and LilyPond's events.
    func disagreements(_ text: String, _ events: [InterpretedEvent]) -> [String] {
        let tree = SyntaxTree(text)
        let source = SourceText(text)
        var problems: [String] = []
        for ev in events {
            guard let idx = source.index(of: SourcePosition(line: ev.line, character: ev.character)) else {
                problems.append("no position \(ev.line):\(ev.character)")
                continue
            }
            let offset = text.utf8.distance(from: text.utf8.startIndex, to: idx)
            let lilyBase = String(ev.duration.prefix { $0 != "*" })
            switch ev.kind {
            case .note:
                if tree.noteIndex(startingAt: offset) == nil, let e = tree.eventIndex(at: offset),
                   tree.events[e].kind == .repeatedPitch {
                    // `c4~ 8`: a bare duration repeats the previous pitch.
                    let model = tree.events[e].effectiveDuration
                    if DurationValue(log: model.log, dots: model.dots).text != lilyBase {
                        problems.append("\(ev.line):\(ev.character) duration model \(model) vs LilyPond \(ev.duration)")
                    }
                    continue
                }
                guard let n = tree.noteIndex(startingAt: offset) else {
                    problems.append("LilyPond note at \(ev.line):\(ev.character) unknown to the model")
                    continue
                }
                let note = tree.notes[n]
                if note.absolute != ev.pitch {
                    problems.append("\(ev.line):\(ev.character) pitch model \(note.absolute) vs LilyPond \(ev.pitch!)")
                }
                if let e = note.event {
                    let model = tree.events[e].effectiveDuration
                    let modelBase = DurationValue(log: model.log, dots: model.dots).text
                    if modelBase != lilyBase {
                        problems.append("\(ev.line):\(ev.character) duration model \(model) vs LilyPond \(ev.duration)")
                    }
                }
            case .rest:
                guard let e = tree.eventIndex(at: offset), tree.events[e].range.lowerBound == offset else {
                    problems.append("LilyPond rest at \(ev.line):\(ev.character) unknown to the model")
                    continue
                }
                let model = tree.events[e].effectiveDuration
                if DurationValue(log: model.log, dots: model.dots).text != lilyBase {
                    problems.append("\(ev.line):\(ev.character) rest duration model \(model) vs LilyPond \(ev.duration)")
                }
            }
        }
        return problems
    }

    func testModelAgreesWithLilyPondOnEveryNote() async throws {
        let lily = try await installation()
        for url in try scores() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let events = try await EventDump.run(lily, source: url)
            XCTAssertGreaterThan(events.count, 20, url.lastPathComponent)
            XCTAssertEqual(disagreements(text, events), [], url.lastPathComponent)
        }
    }

    func testModelStillAgreesAfterRandomEdits() async throws {
        let lily = try await installation()
        // Deterministic by default; set PONDSIDE_ORACLE_SEED to explore.
        let seed = ProcessInfo.processInfo.environment["PONDSIDE_ORACLE_SEED"].flatMap { UInt64($0) } ?? 0x5EED
        print("oracle edit seed: \(seed)")
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for url in try scores() {
            var text = try String(contentsOf: url, encoding: .utf8)
            let work = dir.appendingPathComponent(url.lastPathComponent)
            for round in 0..<8 {
                let tree = SyntaxTree(text)
                let editor = ScoreEditor(tree)
                let candidates = tree.events.indices.filter { tree.events[$0].acceptsNoteEntry && tree.events[$0].kind != .chordRepeat }
                guard !candidates.isEmpty else { break }
                let e = candidates[Int(next() % UInt64(candidates.count))]
                let edit: ScoreEdit?
                switch next() % 5 {
                case 0: edit = editor.move(events: [e], by: .step(next() % 2 == 0 ? 1 : -1))
                case 1: edit = editor.move(events: [e], by: .octave(next() % 2 == 0 ? 1 : -1))
                case 2: edit = editor.setDuration(events: [e], to: DurationValue(log: 1 + Int(next() % 4)))
                case 3: edit = editor.insert(step: Int(next() % 7), after: e, duration: next() % 2 == 0 ? nil : DurationValue(log: 3))
                default: edit = tree.events[e].isPitched ? editor.delete(events: [e]) : nil
                }
                guard let edit, !edit.isEmpty else { continue }
                text = edit.edits.apply(to: text)
                try Data(text.utf8).write(to: work)
                let events: [InterpretedEvent]
                do {
                    events = try await EventDump.run(lily, source: work)
                } catch {
                    XCTFail("\(url.lastPathComponent) round \(round) (\(edit.name)): \(error)")
                    break
                }
                let problems = disagreements(text, events)
                XCTAssertEqual(problems, [], "\(url.lastPathComponent) after round \(round): \(edit.name) \(edit.edits)")
                if !problems.isEmpty { break }
            }
        }
    }
}
