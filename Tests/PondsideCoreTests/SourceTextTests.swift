import XCTest
@testable import PondsideCore

final class SourceTextTests: XCTestCase {
    func testLinesAndPositions() {
        let text = SourceText("ab\ncd\n\nef")
        XCTAssertEqual(text.lineCount, 4)
        XCTAssertEqual(text.lineText(1), "ab")
        XCTAssertEqual(text.lineText(3), "")
        XCTAssertEqual(text.lineText(4), "ef")
        XCTAssertNil(text.lineText(5))

        let i = text.index(of: SourcePosition(line: 2, character: 1))!
        XCTAssertEqual(text.string[i], "d")
        XCTAssertEqual(text.position(of: i), SourcePosition(line: 2, character: 1))
        // End of line is addressable; past it is not.
        XCTAssertNotNil(text.index(of: SourcePosition(line: 2, character: 2)))
        XCTAssertNil(text.index(of: SourcePosition(line: 2, character: 3)))
    }

    /// LilyPond counts point-and-click characters in Unicode scalars, not
    /// bytes or UTF-16 units. Observed with LilyPond 2.24: in
    /// `{ c'4^"ééé" d'4 }` the `d` is reported at char 12.
    func testCharactersAreUnicodeScalars() {
        let text = SourceText("\\version \"2.24.0\"\n{ c'4^\"ééé\" d'4 }\n")
        let i = text.index(of: SourcePosition(line: 2, character: 12))!
        XCTAssertEqual(text.string[i], "d")
        XCTAssertEqual(text.position(of: i).character, 12)
    }

    /// Diagnostics report a 1-based display column with tabs at 8. Observed:
    /// `{\tc4 é d4` → the é is reported at column 12.
    func testDisplayColumnsExpandTabs() {
        let text = SourceText("x\n{\tc4 é d4 \\foo e }\n")
        let p = text.position(line: 2, displayColumn: 12)!
        XCTAssertEqual(p.character, 5)
        XCTAssertEqual(text.string[text.index(of: p)!], "é")
        XCTAssertEqual(text.position(line: 2, displayColumn: 17)?.character, 10) // \foo
    }

    func testCRLFLineEndings() {
        let text = SourceText("a\r\nbc\r\n")
        XCTAssertEqual(text.lineCount, 3)
        let i = text.index(of: SourcePosition(line: 2, character: 1))!
        XCTAssertEqual(text.string.unicodeScalars[i], "c")
    }

    func testUTF16Bridging() {
        let text = SourceText("𝄞 c4")
        let i = text.index(of: SourcePosition(line: 1, character: 2))!
        XCTAssertEqual(text.utf16Offset(of: i), 3)
        XCTAssertEqual(text.index(utf16Offset: 3), i)
    }
}

final class PointAndClickTests: XCTestCase {
    func testParsesLilyPondURI() {
        let loc = PointAndClickLocation(uri: "textedit:///tmp/score.ly:5:20:21")!
        XCTAssertEqual(loc.path, "/tmp/score.ly")
        XCTAssertEqual(loc.line, 5)
        XCTAssertEqual(loc.character, 20)
        XCTAssertEqual(loc.column, 21)
    }

    func testPathWithColonsAndPercentEscapes() {
        let loc = PointAndClickLocation(uri: "textedit:///Users/me/a:b/My%20Score.ly:1:2:3")!
        XCTAssertEqual(loc.path, "/Users/me/a:b/My Score.ly")
        XCTAssertEqual(PointAndClickLocation(uri: loc.uri), loc)
    }

    func testRejectsMalformed() {
        XCTAssertNil(PointAndClickLocation(uri: "http://example.com"))
        XCTAssertNil(PointAndClickLocation(uri: "textedit:///tmp/x.ly:5:20"))
        XCTAssertNil(PointAndClickLocation(uri: "textedit://:1:2:3"))
    }
}

final class LexingTests: XCTestCase {
    private func token(_ s: String, at offset: Int) -> String {
        let i = s.unicodeScalars.index(s.unicodeScalars.startIndex, offsetBy: offset)
        return String(s[LilyLexing.tokenRange(in: s, at: i)])
    }

    func testTokens() {
        let s = "c'4. d8( e) \\fermata <c e g>2~ \"text\" cis''16-."
        XCTAssertEqual(token(s, at: 0), "c'4.")
        XCTAssertEqual(token(s, at: 5), "d8")
        XCTAssertEqual(token(s, at: 12), "\\fermata")
        XCTAssertEqual(token(s, at: 21), "<c e g>2")
        XCTAssertEqual(token(s, at: 31), "\"text\"")
        XCTAssertEqual(token(s, at: 38), "cis''16")
    }
}

final class TextDiffTests: XCTestCase {
    func testMinimalReplacement() {
        let r = TextDiff.minimalReplacement(from: "{ c4 d4 e4 }", to: "{ c4 f4 e4 }")!
        XCTAssertEqual(r, UTF16Replacement(location: 5, length: 1, replacement: "f"))
        XCTAssertNil(TextDiff.minimalReplacement(from: "same", to: "same"))
    }

    func testNeverSplitsSurrogatePairs() {
        // 𝄞 (U+1D11E) and 𝄢 (U+1D122) share a lead surrogate.
        let r = TextDiff.minimalReplacement(from: "a𝄞b", to: "a𝄢b")!
        XCTAssertEqual(r.location, 1)
        XCTAssertEqual(r.length, 2)
        XCTAssertEqual(r.replacement, "𝄢")
    }

    func testCaretMapping() {
        let r = UTF16Replacement(location: 5, length: 1, replacement: "fis")
        XCTAssertEqual(r.mapOffset(2), 2)
        XCTAssertEqual(r.mapOffset(10), 12)
        XCTAssertEqual(r.mapOffset(5), 5)
    }

    /// Property: for random edits, applying the minimal replacement to the
    /// old text reproduces the new text exactly, byte for byte.
    func testRoundTripProperty() {
        var rng = SplitMix64(seed: 0x5EED)
        let alphabet = Array("abcdefg',.~(){}<>\\ \n\t1248é𝄞")
        for _ in 0..<2000 {
            var old = String((0..<Int(rng.next() % 40)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            if old.isEmpty { old = "c" }
            var chars = Array(old)
            let at = Int(rng.next() % UInt64(chars.count + 1))
            let removeCount = min(chars.count - at, Int(rng.next() % 4))
            let insert = (0..<Int(rng.next() % 4)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }
            chars.replaceSubrange(at..<(at + removeCount), with: insert)
            let new = String(chars)
            if let r = TextDiff.minimalReplacement(from: old, to: new) {
                XCTAssertEqual(r.apply(to: old), new)
            } else {
                XCTAssertEqual(old, new)
            }
        }
    }
}

final class VersionAndSyncTests: XCTestCase {
    func testDeclaredVersion() {
        XCTAssertEqual(LilyPondVersion.declared(in: "% \\version \"2.18.2\"\n\\version \"2.26.0\"\n{ c }"), LilyPondVersion(2, 26, 0))
        XCTAssertNil(LilyPondVersion.declared(in: "{ c }"))
        XCTAssertEqual(LilyPondVersion("2.27.3")?.isStable, false)
        XCTAssertTrue(LilyPondVersion(2, 24, 3) < LilyPondVersion(2, 26, 0))
    }

    func testContentHashIsStable() {
        XCTAssertEqual(ContentHash("").description, "cbf29ce484222325")
        XCTAssertNotEqual(ContentHash("a"), ContentHash("b"))
    }

    func testDiskSync() {
        var sync = DiskSync()
        sync.noteSynced("v1")
        XCTAssertEqual(sync.classify(diskText: "v1", bufferText: "v1"), .ignore)
        XCTAssertEqual(sync.classify(diskText: "v2", bufferText: "v1"), .reload)
        XCTAssertEqual(sync.classify(diskText: "v2", bufferText: "local edit"), .conflict)
        XCTAssertEqual(sync.classify(diskText: "same", bufferText: "same"), .ignore)
    }
}

/// Deterministic PRNG so property tests are reproducible on every platform.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
