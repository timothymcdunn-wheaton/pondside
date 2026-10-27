import Foundation
import XCTest
import PondsideEngrave
import PondsideTiming
@testable import PondsideLexicon

final class TOMLTests: XCTestCase {
    func testTheSubsetEntryFilesUse() throws {
        let doc = try TOML.parse("""
        # comment
        schema = 1
        id = "x"   # trailing
        ratio = 0.5
        neg = -3
        big = 1_000
        on = true
        tags = ["a", 'b',
                "c",   # inside
        ]
        literal = 'C:\\path'
        esc = "tab\\there \\"q\\" \\u00e9"
        multi = \"\"\"
        line one
        line two\"\"\"
        "quoted key" = 1

        [params.density]
        type = "float"
        min = 0.0

        [sound]
        params = { density = "density", dur = "spanDur * 2" }
        """)
        XCTAssertEqual(doc["schema"], .integer(1))
        XCTAssertEqual(doc["ratio"], .float(0.5))
        XCTAssertEqual(doc["neg"], .integer(-3))
        XCTAssertEqual(doc["big"], .integer(1000))
        XCTAssertEqual(doc["on"], .bool(true))
        XCTAssertEqual(doc["tags"], .array([.string("a"), .string("b"), .string("c")]))
        XCTAssertEqual(doc["literal"], .string("C:\\path"))
        XCTAssertEqual(doc["esc"], .string("tab\there \"q\" é"))
        XCTAssertEqual(doc["multi"], .string("line one\nline two"))
        XCTAssertEqual(doc["quoted key"], .integer(1))
        XCTAssertEqual(doc["params"]?["density"]?["type"], .string("float"))
        XCTAssertEqual(doc["sound"]?["params"]?["dur"], .string("spanDur * 2"))
    }

    func testErrorsNameTheLine() {
        XCTAssertThrowsError(try TOML.parse("a = 1\na = 2")) { XCTAssertEqual(($0 as? TOMLError)?.line, 2) }
        XCTAssertThrowsError(try TOML.parse("a = \"open"))
        XCTAssertThrowsError(try TOML.parse("[t]\n[t]"))
        XCTAssertThrowsError(try TOML.parse("a = 1 b = 2"))
        XCTAssertThrowsError(try TOML.parse("a = [1, 2"))
    }
}

final class ExpressionTests: XCTestCase {
    func testEvaluation() throws {
        let b: [String: Double] = ["density": 0.5, "spanDur": 8, "tempo": 120]
        XCTAssertEqual(try Expression(parsing: "0.2 + 0.6 * density").evaluate(b), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try Expression(parsing: "(0.2 + 0.6) * density").evaluate(b), 0.4, accuracy: 1e-12)
        XCTAssertEqual(try Expression(parsing: "-spanDur / 2").evaluate(b), -4)
        XCTAssertEqual(try Expression(parsing: "min(1, tempo / 60, 3)").evaluate(b), 1)
        XCTAssertEqual(try Expression(parsing: "max(density, 0.9)").evaluate(b), 0.9)
        XCTAssertEqual(try Expression(parsing: "8 - 2 - 1").evaluate([:]), 5, "left-associative")
        XCTAssertEqual(try Expression(parsing: "spanDur * density + tempo").names, ["spanDur", "density", "tempo"])
    }

    func testTheLanguageIsTotal() {
        XCTAssertThrowsError(try Expression(parsing: "sin(1)"))
        XCTAssertThrowsError(try Expression(parsing: "max(1)"))
        XCTAssertThrowsError(try Expression(parsing: "1 +"))
        XCTAssertThrowsError(try Expression(parsing: "(1"))
        XCTAssertThrowsError(try Expression(parsing: "1 2"))
        XCTAssertThrowsError(try Expression(parsing: "1 / x").evaluate(["x": 0]))
        XCTAssertThrowsError(try Expression(parsing: "y").evaluate([:]))
    }
}

final class EntryTests: XCTestCase {
    /// The schema example from DESIGN.md §3.
    static let breathCloud = """
    schema   = 1
    id       = "breath-cloud"
    version  = "1.2.0"
    gloss    = "Widening cloud of stemless noteheads, density rising over a span"
    tags     = ["texture", "aleatoric", "graphic", "winds"]
    kind     = "texture"

    [entry]
    attaches = "span"
    music-arg = true

    [params.span]
    type    = "int"
    default = 4
    min     = 1

    [params.density]
    type    = "float"
    default = 0.6
    min     = 0.0
    max     = 1.0

    [params.shape]
    type    = "enum"
    values  = ["widen", "narrow", "steady"]
    default = "widen"

    [sound]
    synthdef = "granularCloud"
    cue      = "breathCloud"
    params   = { density = "density", dur = "spanDur", amp = "0.2 + 0.6 * density" }
    """

    func testTheDesignExampleIsValid() throws {
        let e = try LexiconEntry(toml: Self.breathCloud, directoryName: "breath-cloud")
        XCTAssertEqual(e.params.map(\.name), ["span", "density", "shape"], "params keep file order")
        XCTAssertEqual(e.sound?.params.map(\.name), ["density", "dur", "amp"])
        let values = try e.resolve(["density": .float(0.8)])
        XCTAssertEqual(values["span"], .integer(4))
        let sound = try e.soundParams(values, beatDur: 0.5, spanDur: 8, tempo: 120)
        XCTAssertEqual(sound.map(\.0), ["density", "dur", "amp"])
        XCTAssertEqual(sound[2].1, 0.68, accuracy: 1e-12)
        XCTAssertEqual(sound[1].1, 8)
    }

    func testEveryProblemIsReportedAtOnce() {
        let bad = """
        schema = 1
        id = "Bad_Name"
        version = "1.2"
        gloss = "\(String(repeating: "x", count: 90))"
        kind = "blob"
        [params.d]
        type = "float"
        default = 2.0
        max = 1.0
        [params.e]
        type = "enum"
        [sound]
        params = { a = "nope * 2" }
        """
        XCTAssertThrowsError(try LexiconEntry(toml: bad, directoryName: "bad")) { error in
            let messages = (error as? LexiconProblems)?.problems.map(\.message) ?? []
            XCTAssertTrue(messages.contains { $0.contains("kebab-case") }, "\(messages)")
            XCTAssertTrue(messages.contains { $0.contains("semver") })
            XCTAssertTrue(messages.contains { $0.contains("tier 0 allows 80") })
            XCTAssertTrue(messages.contains { $0.contains("kind must be") })
            XCTAssertTrue(messages.contains { $0.contains("above the maximum") })
            XCTAssertTrue(messages.contains { $0.contains("enum without values") })
            XCTAssertTrue(messages.contains { $0.contains("reads nope") })
            XCTAssertTrue(messages.contains { $0.contains("sound.cue is required") })
            XCTAssertTrue(messages.contains { $0.contains("differs from its folder") })
        }
    }

    func testResolveRejectsUnknownAndOutOfRange() throws {
        let e = try LexiconEntry(toml: Self.breathCloud)
        XCTAssertThrowsError(try e.resolve(["densty": .float(0.5)]))
        XCTAssertThrowsError(try e.resolve(["density": .float(1.5)]))
        XCTAssertThrowsError(try e.resolve(["shape": .string("round")]))
        XCTAssertThrowsError(try e.resolve(["span": .float(2.5)]))
    }
}

final class LibraryTests: XCTestCase {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-lexicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func write(_ root: URL, _ id: String, toml: String, impl: String = "% impl\n") throws {
        let d = root.appendingPathComponent("entries/\(id)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try toml.write(to: d.appendingPathComponent("entry.toml"), atomically: true, encoding: .utf8)
        try impl.write(to: d.appendingPathComponent("impl.ily"), atomically: true, encoding: .utf8)
        try "Readme for \(id).\n".write(to: d.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    func testCoreEntriesAreValid() {
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        XCTAssertTrue(lex.problems.isEmpty, lex.problems.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(lex.ids, ["air-tone", "feathered-beam", "niente-hairpin", "timed-fermata"])
        let index = lex.indexJSON()
        XCTAssertEqual(index.split(separator: "\n").count, 6, "one line per entry between [ and ]")
        XCTAssertTrue(index.contains("{\"gloss\":\"Air sound"))
        // Tier 0 stays cheap: well under 100 tokens (~400 characters) an entry.
        XCTAssertLessThan(index.count / 4, 400)
        XCTAssertTrue(lex.tier1("air-tone")?.contains("[sound]") ?? false)
        XCTAssertTrue(lex.tier2("air-tone")?.contains("pondside-lexicon-register!") ?? false)
    }

    func testLaterScopesOverride() throws {
        let user = try temp(), project = try temp()
        let base = EntryTests.breathCloud
        try write(user, "breath-cloud", toml: base)
        try write(project, "breath-cloud", toml: base.replacingOccurrences(of: "1.2.0", with: "2.0.0"))
        try write(project, "broken", toml: "schema = 1\nid = \"broken\"\n")
        let lex = Lexicon.load([(.user, user), (.project, project)])
        XCTAssertEqual(lex.entries["breath-cloud"]?.entry.version, "2.0.0")
        XCTAssertEqual(lex.entries["breath-cloud"]?.scope, .project)
        XCTAssertEqual(lex.shadowed.map(\.scope), [.user])
        XCTAssertNil(lex.entries["broken"])
        XCTAssertFalse(lex.problems.isEmpty)
    }

    func testUsesAreCheckedBeforeCompiling() throws {
        let user = try temp()
        try write(user, "breath-cloud", toml: EntryTests.breathCloud)
        let lex = Lexicon.load([(.user, user)])
        let score = """
        % \\lexicon "commented-out" #'()
        { \\lexicon "breath-cloud" #'((density . 1) (shape . narrow)) { c'1 }
          \\lexicon "breath-cloud" #'((density . 3/2)) { c'1 }
          \\lexicon "breath-clod" #'() { c'1 } }
        """
        let uses = LexiconUse.find(in: score)
        XCTAssertEqual(uses.map(\.id), ["breath-cloud", "breath-cloud", "breath-clod"])
        XCTAssertEqual(uses[0].params["shape"], .string("narrow"))
        let problems = lex.check(score)
        XCTAssertEqual(problems.map(\.line), [3, 4])
        XCTAssertTrue(problems[0].message.contains("above the maximum"))
        XCTAssertTrue(problems[1].message.contains("did you mean breath-cloud"))
    }
}

/// Every core entry engraves with LilyPond, and sound bindings place cues.
final class LexiconEngravingTests: XCTestCase {
    func compile(_ body: String) async throws -> (EngraveResult, URL, LilyPondInstallation) {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-lexicon-ly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let include = dir.appendingPathComponent("lexicon.ily")
        try lex.includeFile(for: Set(lex.ids)).write(to: include, atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("score.ly")
        try "\\version \"2.24.0\"\n\\include \"lexicon.ily\"\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        return (result, file, lily)
    }

    func testEveryCoreEntryEngraves() async throws {
        let (result, _, _) = try await compile("""
        \\relative c'' {
          \\lexicon "niente-hairpin" #'() { c2\\> c4 r\\! }
          \\lexicon "timed-fermata" #'((seconds . 6)) { g1 }
          \\lexicon "air-tone" #'((amount . 0.8) (label . "air")) { d2 e }
          \\lexicon "feathered-beam" #'((direction . "rit")) { c16[ d e f g a b c] }
        }
        """)
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(result.errors.isEmpty, result.log)
        XCTAssertFalse(result.log.contains("Lexicon has no entry"), result.log)
    }

    func testSoundBindingsPlaceCuesAndHoldsTime() async throws {
        let (result, file, lily) = try await compile("""
        \\score { \\relative c'' {
          \\tempo 4 = 60
          c4 \\lexicon "timed-fermata" #'((seconds . 6) (resume . 60)) { g1 }
          \\lexicon "air-tone" #'() { d2 e } } \\layout { } }
        """)
        XCTAssertTrue(result.succeeded, result.log)
        let log = try await TimingDump.run(lily, source: file)
        let sheet = CueSheet(log: log, score: "score.ly")
        // c4 (1 s) + the hold (6 s): the air-tone cue at 7 s.
        XCTAssertEqual(sheet.cues.map(\.name), ["airTone"])
        XCTAssertEqual(sheet.cues.first?.seconds ?? 0, 7, accuracy: 1e-6)
        XCTAssertEqual(sheet.cues.first?.position.moment, "5/4")
    }
}
