import Foundation
import PondsideCore
import PondsideEngrave
import PondsideLexicon

/// Putting a graphic into a score, and what it needs to compile: the
/// minimal edits an agent's `graphic_insert` makes (DESIGN.md §8).
public enum GraphicEdit {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        init(_ d: String) { description = d }
    }

    /// `\startGraphic "id" #'params` on the event at `start`, `\stopGraphic`
    /// on the event at `stop`; both in the same staff's music. Returns the
    /// new text. Nothing else moves.
    public static func insert(into text: String, id: String, params: String,
                              start: (line: Int, character: Int), stop: (line: Int, character: Int)) throws -> String {
        let tree = SyntaxTree(text)
        guard let s = event(tree, text, start), let e = event(tree, text, stop) else {
            throw Failure("start and stop must each be on a note, rest or skip")
        }
        guard e > s else { throw Failure("the graphic must stop on a later event than it starts") }
        let block = LensBlockFinder.block(in: tree, at: tree.events[s].range.lowerBound)
        guard let block, block.events.contains(e) else {
            throw Failure("start and stop are in different staves' music; a graphic spans one staff")
        }
        let alist = params.trimmingCharacters(in: .whitespaces).isEmpty ? "'()" : params.trimmingCharacters(in: .whitespaces)
        let quoted = alist.hasPrefix("'") ? alist : "'" + alist
        let edits = [
            TextEdit.insert("\\startGraphic \"\(id)\" #\(quoted)", at: tree.events[s].range.upperBound),
            TextEdit.insert("\\stopGraphic", at: tree.events[e].range.upperBound),
        ]
        return edits.apply(to: text)
    }

    /// The event at the position; else the next one on the same line, else
    /// the previous one on it (an agent's character may land on a space).
    static func event(_ tree: SyntaxTree, _ text: String, _ p: (line: Int, character: Int)) -> Int? {
        guard let offset = ScoreContext.utf8Offset(in: text, line: p.line, character: p.character) else { return nil }
        if let e = tree.events.firstIndex(where: { $0.range.contains(offset) || $0.range.lowerBound == offset }) { return e }
        let onLine = tree.events.indices.filter { ScoreContext.lineNumber(of: tree.events[$0].range.lowerBound, in: text) == p.line }
        return onLine.first { tree.events[$0].range.lowerBound > offset } ?? onLine.last { tree.events[$0].range.upperBound <= offset }
    }

    /// Writes `lexicon.ily` beside `root` for every entry used anywhere in
    /// the score's include graph, and adds `\include "lexicon.ily"` to the
    /// root after its `\version` if it isn't there. Returns the include file.
    @discardableResult
    public static func prepareLexiconInclude(root: URL, lexicon: Lexicon) throws -> URL {
        let graph = SourceGraph.load(root: root)
        let used = Set(graph.files.flatMap { LexiconUse.find(in: $0.text).map(\.id) })
        let include = root.deletingLastPathComponent().appendingPathComponent("lexicon.ily")
        try Data(lexicon.includeFile(for: used).utf8).write(to: include, options: .atomic)
        let text = try String(contentsOf: root, encoding: .utf8)
        if !text.contains("\\include \"lexicon.ily\"") {
            try Data(withLexiconInclude(text).utf8).write(to: root, options: .atomic)
        }
        return include
    }

    /// `\include "lexicon.ily"` on the line after `\version`, or first.
    public static func withLexiconInclude(_ text: String) -> String {
        let line = "\\include \"lexicon.ily\"\n"
        guard let v = text.range(of: "\\version") else { return line + text }
        let end = text[v.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
        return String(text[..<end]) + (end == text.endIndex && !text.hasSuffix("\n") ? "\n" : "") + line + String(text[end...])
    }

    /// A small score showing an entry: a graphic over `bars` bars on its own
    /// staff (with `music` above, if given), or another entry's example
    /// invocation from its entry.toml.
    public static func previewSource(entry: LexiconEntry, params: String = "()", bars: Int = 4, music: String? = nil) -> String {
        let body: String
        if entry.kind == .graphic {
            let rest = bars > 1 ? "s1*\(bars - 1)" : ""
            let above = music.map { "\\new Staff { \($0) }\n" } ?? ""
            // It stops on a short skip after the span: a zero-length one at the
            // very end of a score leaves the spanner without a breakable bound.
            body = "<<\n\(above)\\new Staff { s1\\startGraphic \"\(entry.id)\" #'\(params) \(rest) s16\\stopGraphic }\n>>"
        } else {
            body = "\\new Staff { \(entry.command ?? "c''1") }"
        }
        return """
        \\version "2.24.0"
        \\include "lexicon.ily"
        \\paper { indent = 0 tagline = ##f }
        \\score { \(body) \\layout { } }

        """
    }
}
