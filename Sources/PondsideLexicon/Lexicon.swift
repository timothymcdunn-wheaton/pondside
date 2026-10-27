import Foundation

/// The Lexicon: entries from three scopes, later scopes overriding earlier
/// ones by id (core → user → project), read in three tiers of detail so an
/// agent can browse a hundred entries for about two thousand tokens.
public struct Lexicon: Sendable {
    public enum Scope: String, CaseIterable, Codable, Sendable { case core, user, project }

    public struct Loaded: Sendable, Hashable {
        public var entry: LexiconEntry
        public var scope: Scope
        public var directory: URL
    }

    public private(set) var entries: [String: Loaded] = [:]
    /// Entries hidden by a later scope's entry of the same id.
    public private(set) var shadowed: [Loaded] = []
    /// Entries that failed validation (they are left out, never half-used).
    public private(set) var problems: [LexiconEntry.Problem] = []

    public init() {}

    /// Loads `<root>/entries/*/entry.toml` for each scope, in order.
    public static func load(_ scopes: [(Scope, URL)]) -> Lexicon {
        var lex = Lexicon()
        let fm = FileManager.default
        for (scope, root) in scopes {
            let entriesDir = root.appendingPathComponent("entries")
            guard let names = try? fm.contentsOfDirectory(atPath: entriesDir.path) else { continue }
            for name in names.sorted() {
                let dir = entriesDir.appendingPathComponent(name)
                guard let data = fm.contents(atPath: dir.appendingPathComponent("entry.toml").path) else { continue }
                do {
                    let entry = try LexiconEntry(toml: String(decoding: data, as: UTF8.self), directoryName: name)
                    if !fm.fileExists(atPath: dir.appendingPathComponent(entry.implFile).path) {
                        lex.problems.append(.init(entry: entry.id, message: "\(entry.implFile) is missing"))
                        continue
                    }
                    if let old = lex.entries[entry.id] { lex.shadowed.append(old) }
                    lex.entries[entry.id] = Loaded(entry: entry, scope: scope, directory: dir)
                } catch let e as LexiconProblems {
                    lex.problems += e.problems
                } catch {
                    lex.problems.append(.init(entry: name, message: "\(error)"))
                }
            }
        }
        return lex
    }

    /// The standard scopes: the bundled core, the user's library, and the
    /// project's `Lexicon/` folder beside the score (if any).
    public static func standardScopes(project: URL?) -> [(Scope, URL)] {
        var out: [(Scope, URL)] = []
        if let core = Bundle.module.url(forResource: "Core", withExtension: nil) {
            out.append((.core, core.appendingPathComponent("Lexicon")))
        }
        out.append((.user, userDirectory))
        if let project { out.append((.project, project.appendingPathComponent("Lexicon"))) }
        return out
    }

    public static var userDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["PONDSIDE_LEXICON"] { return URL(fileURLWithPath: custom) }
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pondside/Lexicon")
        #else
        let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("pondside/Lexicon")
        #endif
    }

    public var ids: [String] { entries.keys.sorted() }

    // MARK: Tiers

    struct IndexLine: Encodable {
        var id: String
        var gloss: String
        var kind: String
        var tags: [String]
        var params: [String]
        var sound: Bool
    }

    /// Tier 0: `index.json`, one line per entry sorted by id, so it diffs
    /// cleanly and costs about twenty tokens an entry.
    public func indexJSON() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = ids.compactMap { id -> String? in
            guard let l = entries[id] else { return nil }
            let line = IndexLine(id: id, gloss: l.entry.gloss, kind: l.entry.kind.rawValue, tags: l.entry.tags,
                                 params: l.entry.params.map(\.name), sound: l.entry.sound != nil)
            return (try? e.encode(line)).map { String(decoding: $0, as: UTF8.self) }
        }
        return lines.isEmpty ? "[]\n" : "[\n" + lines.joined(separator: ",\n") + "\n]\n"
    }

    /// Tier 1: the whole entry.toml and the README.
    public func tier1(_ id: String) -> String? {
        guard let l = entries[id] else { return nil }
        let toml = (try? String(contentsOf: l.directory.appendingPathComponent("entry.toml"), encoding: .utf8)) ?? ""
        let readme = (try? String(contentsOf: l.directory.appendingPathComponent(l.entry.readmeFile), encoding: .utf8)) ?? ""
        return "# \(id) \(l.entry.version) (\(l.scope.rawValue))\n\n```toml\n\(toml)```\n\n\(readme)"
    }

    /// Tier 2: the implementation, for adapting it.
    public func tier2(_ id: String) -> String? {
        guard let l = entries[id] else { return nil }
        return try? String(contentsOf: l.directory.appendingPathComponent(l.entry.implFile), encoding: .utf8)
    }

    // MARK: Engraving

    /// The settings file that makes `\lexicon "id" #'(…) music` work for
    /// `ids`: the dispatcher, each entry's defaults, its implementation, and
    /// a cue for entries that carry a sound.
    public func includeFile(for ids: Set<String>) -> String {
        var out = """
        % Generated by Pondside: the Lexicon entries this score uses.
        #(define pondside-lexicon-impls (make-hash-table))
        #(define pondside-lexicon-defaults (make-hash-table))
        #(define pondside-lexicon-cues (make-hash-table))
        #(define (pondside-lexicon-register! id proc) (hash-set! pondside-lexicon-impls id proc))

        """
        for id in ids.sorted() {
            guard let l = entries[id] else { continue }
            let defaults = l.entry.params.compactMap { p -> String? in
                p.defaultValue.map { "(\(p.name) . \(Self.scheme($0)))" }
            }
            out += "#(hash-set! pondside-lexicon-defaults \(Self.schemeString(id)) '(\(defaults.joined(separator: " "))))\n"
            if let cue = l.entry.sound?.cue {
                out += "#(hash-set! pondside-lexicon-cues \(Self.schemeString(id)) \(Self.schemeString(cue)))\n"
            }
            out += "\\include \(Self.schemeString(l.directory.appendingPathComponent(l.entry.implFile).path))\n"
        }
        out += """

        lexicon =
        #(define-music-function (id params music) (string? list? ly:music?)
           (let ((proc (hash-ref pondside-lexicon-impls id #f))
                 (defaults (hash-ref pondside-lexicon-defaults id '()))
                 (cue (hash-ref pondside-lexicon-cues id #f)))
             (if (not proc)
                 (begin (ly:input-warning (*location*) "Lexicon has no entry ~a" id) music)
                 (let* ((merged (append params (filter (lambda (d) (not (assq (car d) params))) defaults)))
                        (result (proc merged music)))
                   (if cue
                       (let ((ev (make-music 'TextScriptEvent 'direction UP 'text "" 'cue-label cue)))
                         (ly:music-set-property! ev 'tweaks (list (cons 'stencil #f)))
                         (make-sequential-music (list (make-music 'EventChord 'elements (list ev)) result)))
                       result)))))

        """
        return out
    }

    static func scheme(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s): return schemeString(s)
        case .integer(let i): return String(i)
        case .float(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) + ".0" : String(d)
        case .bool(let b): return b ? "#t" : "#f"
        case .array(let a): return "(" + a.map(scheme).joined(separator: " ") + ")"
        case .table: return "'()"
        }
    }

    static func schemeString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
