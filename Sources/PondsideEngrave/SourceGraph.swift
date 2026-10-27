import Foundation
import PondsideCore

/// The files a score is made of: the root and everything it `\include`s.
///
/// Real projects keep their music in included files (musicxml2ly output,
/// house `defs.ily`, one file per part), so editing has to work across them.
/// The graph resolves includes the way LilyPond does and parses each file in
/// context: a `\language` set in an earlier include applies to later files.
public struct SourceGraph: Sendable {
    public struct File: Sendable {
        /// Canonical location (symlinks resolved).
        public var url: URL
        public var text: String
        public var tree: SyntaxTree
        /// The note-name language in effect where the file is included.
        public var entryLanguage: PitchLanguage
        /// The file that first includes this one; nil for the root.
        public var includedFrom: URL?
    }

    /// The root first, then files in first-inclusion order.
    public var files: [File]
    /// `\include` strings that resolve to no file on disk. LilyPond's own
    /// includes (`english.ly`, `articulate.ly`) land here and are fine.
    public var unresolved: [String]

    public var root: File { files[0] }

    public func file(_ url: URL) -> File? {
        let c = Self.canonical(url)
        return files.first { $0.url == c }
    }

    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves an include string as LilyPond does with relative includes:
    /// the including file's directory first, then the root's directory, then
    /// any search paths (`-I`).
    public static func resolve(_ include: String, from includer: URL, root: URL, searchPaths: [URL] = [],
                               exists: (URL) -> Bool) -> URL? {
        if include.hasPrefix("/") {
            let u = URL(fileURLWithPath: include)
            return exists(u) ? canonical(u) : nil
        }
        let bases = [includer.deletingLastPathComponent(), root.deletingLastPathComponent()] + searchPaths
        for base in bases {
            let u = base.appendingPathComponent(include)
            if exists(u) { return canonical(u) }
        }
        return nil
    }

    /// Loads the graph from disk.
    ///
    /// - Parameter overrides: in-memory texts that take precedence over the
    ///   files on disk (unsaved edits).
    public static func load(root: URL, overrides: [URL: String] = [:], searchPaths: [URL] = []) -> SourceGraph {
        let fm = FileManager.default
        let rootURL = canonical(root)
        var cache: [URL: String] = [:]
        for (k, v) in overrides { cache[canonical(k)] = v }
        func read(_ u: URL) -> String? {
            if let t = cache[u] { return t }
            guard let d = fm.contents(atPath: u.path) else { return nil }
            let t = String(decoding: d, as: UTF8.self)
            cache[u] = t
            return t
        }
        func exists(_ u: URL) -> Bool {
            cache[canonical(u)] != nil || fm.fileExists(atPath: u.path)
        }

        // Languages left in effect by each file, refined until stable: an
        // include's outcome can depend on the language it is entered with.
        var finalLanguage: [URL: PitchLanguage] = [:]
        var result = SourceGraph(files: [], unresolved: [])
        for _ in 0..<4 {
            var files: [File] = []
            var unresolved: [String] = []
            var visited = Set<URL>()
            var changed = false

            func visit(_ url: URL, entry: PitchLanguage, from: URL?) {
                guard !visited.contains(url), let text = read(url) else { return }
                visited.insert(url)
                let tree = SyntaxTree(text, language: entry) { include in
                    resolve(include, from: url, root: rootURL, searchPaths: searchPaths, exists: exists)
                        .flatMap { finalLanguage[$0] }
                }
                files.append(File(url: url, text: text, tree: tree, entryLanguage: entry, includedFrom: from))
                for inc in tree.includes {
                    guard let child = resolve(inc.path, from: url, root: rootURL, searchPaths: searchPaths, exists: exists) else {
                        unresolved.append(inc.path)
                        continue
                    }
                    visit(child, entry: inc.language, from: url)
                }
                if finalLanguage[url] != tree.finalLanguage {
                    finalLanguage[url] = tree.finalLanguage
                    changed = true
                }
            }

            visit(rootURL, entry: .nederlands, from: nil)
            result = SourceGraph(files: files, unresolved: unresolved)
            if !changed { break }
        }
        if result.files.isEmpty {
            // Unreadable root: an empty stand-in keeps callers simple.
            result.files = [File(url: rootURL, text: "", tree: SyntaxTree(""), entryLanguage: .nederlands, includedFrom: nil)]
        }
        return result
    }
}
