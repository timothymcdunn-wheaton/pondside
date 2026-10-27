/// Keeps a SuperCollider file of cue handlers in step with the score.
///
/// Each cue owns a block between marker comments:
///
///     // @pondside cue cue-12 · bar 42 beat 1 · 133.333 s
///     p.on(\cue12, { |cue|
///         … the composer's code …
///     });
///     // @pondside end cue-12
///
/// Pondside rewrites only the header line (where and when the cue is).
/// Everything between the header and the end marker belongs to the
/// composer and is never changed — except that when a cue leaves the score
/// its block is commented out line by line (`//~ `), and restored exactly
/// if the cue comes back. New cues get empty stubs in score order.
public enum HandlerSync {
    public static let headerPrefix = "// @pondside cue "
    public static let orphanPrefix = "// @pondside orphan "
    public static let endPrefix = "// @pondside end "
    static let commented = "//~ "

    /// The first version of the file.
    public static func starter(_ sheet: CueSheet, projectPath: String) -> String {
        var out = """
        // Cue handlers for \(sheet.score), kept in sync by Pondside.
        // Write anything inside a handler: Pondside only adds stubs for new cues,
        // updates the comment line above each handler, and comments out
        // handlers whose cue has left the score (restoring them if it returns).
        p = Pondside("\(projectPath)");


        """
        for cue in sheet.cues { out += stub(cue) + "\n" }
        out += "// p.play;   // or p.play(from: \"12:1\")\n"
        return out
    }

    public static func header(_ cue: CueSheet.Cue) -> String {
        var where_ = "bar \(cue.position.measure)"
        if let b = cue.position.beat { where_ += " beat " + format(b) }
        return headerPrefix + cue.id + " · " + where_ + " · " + seconds(cue.seconds) + " s"
    }

    static func stub(_ cue: CueSheet.Cue) -> String {
        """
        \(header(cue))
        p.on(\\\(cue.handler), { |cue|
        \t// cue \(cue.name) at moment \(cue.position.moment)
        });
        \(endPrefix)\(cue.id)

        """
    }

    struct Block {
        var id: String
        var orphan: Bool
        /// Line indices of the header and the end marker.
        var header: Int
        var end: Int
    }

    static func blocks(_ lines: [String]) -> [Block] {
        var out: [Block] = []
        var open: (id: String, orphan: Bool, header: Int)?
        for (i, line) in lines.enumerated() {
            if let o = open {
                if line == endPrefix + o.id {
                    out.append(Block(id: o.id, orphan: o.orphan, header: o.header, end: i))
                    open = nil
                }
                continue
            }
            if line.hasPrefix(headerPrefix) {
                open = (id(after: headerPrefix, in: line), false, i)
            } else if line.hasPrefix(orphanPrefix) {
                open = (id(after: orphanPrefix, in: line), true, i)
            }
        }
        return out
    }

    private static func id(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count).prefix { $0 != " " })
    }

    public struct Report: Sendable, Hashable {
        public var added: [String] = []
        public var orphaned: [String] = []
        public var restored: [String] = []
        public var moved: [String] = []
    }

    /// Brings `existing` up to date with `sheet`.
    public static func sync(_ existing: String, with sheet: CueSheet) -> (text: String, report: Report) {
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var report = Report()
        let wanted = Dictionary(sheet.cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Update, orphan and restore in place, back to front so indices hold.
        for b in blocks(lines).reversed() {
            if let cue = wanted[b.id] {
                let newHeader = header(cue)
                if b.orphan {
                    for i in (b.header + 1)..<b.end where lines[i].hasPrefix(commented) {
                        lines[i] = String(lines[i].dropFirst(commented.count))
                    }
                    report.restored.append(b.id)
                } else if lines[b.header] != newHeader {
                    report.moved.append(b.id)
                }
                lines[b.header] = newHeader
            } else if !b.orphan {
                lines[b.header] = orphanPrefix + b.id + " · its cue is no longer in the score"
                for i in (b.header + 1)..<b.end { lines[i] = commented + lines[i] }
                report.orphaned.append(b.id)
            }
        }

        // Stubs for new cues, each after the block of the cue before it.
        var present = Set(blocks(lines).map(\.id))
        for (i, cue) in sheet.cues.enumerated() where !present.contains(cue.id) {
            let current = blocks(lines)
            let previous = sheet.cues[..<i].reversed().first { c in current.contains { $0.id == c.id } }
            let at: Int
            if let previous, let b = current.first(where: { $0.id == previous.id }) {
                at = b.end + 1
            } else if let first = current.first {
                at = first.header
            } else {
                // Before a trailing `p.play` line if there is one, else at the end.
                at = lines.lastIndex { $0.contains("p.play") } ?? lines.count
            }
            var stubLines = stub(cue).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if stubLines.last == "" { stubLines.removeLast() }
            if at > 0, at <= lines.count, lines[at - 1].hasPrefix(endPrefix) { stubLines.insert("", at: 0) }
            if at < lines.count, !lines[at].isEmpty { stubLines.append("") }
            lines.insert(contentsOf: stubLines, at: at)
            present.insert(cue.id)
            report.added.append(cue.id)
        }
        report.orphaned.reverse()
        report.restored.reverse()
        report.moved.reverse()
        return (lines.joined(separator: "\n"), report)
    }

    private static func seconds(_ s: Double) -> String {
        let ms = Int((s * 1000).rounded())
        let frac = ms % 1000
        return "\(ms / 1000)." + String(repeating: "0", count: 3 - String(frac).count) + String(frac)
    }

    private static func format(_ b: Double) -> String {
        b == b.rounded() ? String(Int(b)) : String((b * 1000).rounded() / 1000)
    }
}
