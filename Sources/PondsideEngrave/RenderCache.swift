import Foundation
import PondsideCore

/// The latest engraving of each score, so reopening one shows its music at
/// once while LilyPond engraves it afresh.
///
/// A cache, not score state: everything in it is derived from the `.ly`
/// files, it may be deleted at any time, and it never sits beside the
/// score. Each score has one entry, replaced whole on every engraving that
/// produced pages. An entry is LilyPond's own SVG pages plus a manifest
/// with the text of each file as engraved, so links on the cached pages
/// map onto text that has changed since.
public struct RenderCache: Sendable {
    /// e.g. `~/Library/Caches/Pondside/Renders`; the platform layer picks it.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public struct Entry: Sendable, Equatable {
        /// SVG pages, in order.
        public var pages: [Data]
        /// Each file's text as LilyPond read it, by standardized path.
        public var snapshots: [String: String]
        public var lilypondVersion: String?
        public var date: Date

        public init(pages: [Data], snapshots: [String: String], lilypondVersion: String?, date: Date = Date()) {
            self.pages = pages
            self.snapshots = snapshots
            self.lilypondVersion = lilypondVersion
            self.date = date
        }
    }

    private struct Manifest: Codable {
        static let currentFormat = 1
        var format = Manifest.currentFormat
        var score: String
        var lilypond: String?
        var date: Date
        var pages: [String]
        var snapshots: [String: String]
    }

    private static let manifestName = "manifest.json"

    /// The entry's folder: a hash of the score's path. The manifest names
    /// the score too, so a hash collision reads as a miss, not as music
    /// from another score.
    public func directory(for score: URL) -> URL {
        root.appendingPathComponent(ContentHash(Self.key(score)).description, isDirectory: true)
    }

    private static func key(_ score: URL) -> String { score.standardizedFileURL.path }

    /// Replaces the score's entry. The new entry is written beside the old
    /// one and swapped in by renaming, so a crash never leaves half of one.
    public func store(_ entry: Entry, for score: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var names: [String] = []
            for (index, page) in entry.pages.enumerated() {
                let name = "page-\(index + 1).svg"
                try page.write(to: staging.appendingPathComponent(name))
                names.append(name)
            }
            let manifest = Manifest(score: Self.key(score), lilypond: entry.lilypondVersion, date: entry.date,
                                    pages: names, snapshots: entry.snapshots)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName))

            let destination = directory(for: score)
            let retired = root.appendingPathComponent(".retired-\(UUID().uuidString)", isDirectory: true)
            let replacing = fm.fileExists(atPath: destination.path)
            if replacing { try fm.moveItem(at: destination, to: retired) }
            try fm.moveItem(at: staging, to: destination)
            if replacing { try? fm.removeItem(at: retired) }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// The score's entry, or nil if there is none or it can't be read whole.
    /// Reading it marks it recently used.
    public func load(for score: URL) -> Entry? {
        let fm = FileManager.default
        let folder = directory(for: score)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)),
              let manifest = try? decoder.decode(Manifest.self, from: data),
              manifest.format == Manifest.currentFormat, manifest.score == Self.key(score), !manifest.pages.isEmpty
        else { return nil }
        var pages: [Data] = []
        for name in manifest.pages {
            guard !name.contains("/"), let page = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            pages.append(page)
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return Entry(pages: pages, snapshots: manifest.snapshots, lilypondVersion: manifest.lilypond, date: manifest.date)
    }

    public func remove(for score: URL) {
        try? FileManager.default.removeItem(at: directory(for: score))
    }

    /// Keeps the `entries` most recently used entries within `bytes`, and
    /// clears leftovers of interrupted stores.
    public func prune(entries: Int = 50, bytes: Int = 500_000_000) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        var kept: [(url: URL, date: Date, size: Int)] = []
        for child in children {
            if child.lastPathComponent.hasPrefix(".") {
                try? fm.removeItem(at: child)
                continue
            }
            let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            kept.append((child, date, Self.size(of: child)))
        }
        kept.sort { $0.date > $1.date }
        var total = 0
        for (index, entry) in kept.enumerated() {
            total += entry.size
            if index >= entries || total > bytes { try? fm.removeItem(at: entry.url) }
        }
    }

    private static func size(of folder: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.reduce(0) { sum, name in
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return sum + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }
}
