import Foundation

/// `pondside.toml` at a project's root: settings a piece needs everywhere,
/// in one human-readable, git-committable file.
///
///     [lilypond]
///     version = "2.26.0"          # the version this piece compiles with
///
///     [audio]
///     sample-rate = 48000         # mockup and cue samples; the quark checks it
///     renderer = "musescore"      # or "fluidsynth"
///     soundfont = "sounds/piano.sf2"
///
///     [supercollider]
///     handlers = "patch/cues.scd" # kept in sync by `pondside handlers`
///     resources = "patch/resources"
public struct ProjectConfig: Sendable, Hashable {
    /// The folder holding pondside.toml (relative paths resolve against it).
    public var root: URL
    public var lilypondVersion: String?
    public var sampleRate: Int
    public var renderer: String?
    public var soundFont: URL?
    public var handlers: URL?
    public var resources: URL?

    public static let fileName = "pondside.toml"

    public init(root: URL) {
        self.root = root
        self.sampleRate = 48000
    }

    public init(toml text: String, root: URL) throws {
        let doc = try TOML.parse(text)
        self.init(root: root)
        func path(_ v: TOMLValue?) -> URL? {
            guard let s = v?.string, !s.isEmpty else { return nil }
            return s.hasPrefix("/") ? URL(fileURLWithPath: s) : root.appendingPathComponent(s)
        }
        lilypondVersion = doc["lilypond"]?["version"]?.string
        if let r = doc["audio"]?["sample-rate"]?.int {
            guard [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000].contains(r) else {
                throw TOMLError(line: 0, message: "audio.sample-rate \(r) is not a standard rate")
            }
            sampleRate = r
        }
        renderer = doc["audio"]?["renderer"]?.string
        soundFont = path(doc["audio"]?["soundfont"])
        handlers = path(doc["supercollider"]?["handlers"])
        resources = path(doc["supercollider"]?["resources"])
    }

    /// The nearest pondside.toml at or above `start` (a file or a folder);
    /// defaults rooted at the score's folder when there is none.
    public static func find(from start: URL) throws -> ProjectConfig {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        let fallback = dir
        while true {
            let candidate = dir.appendingPathComponent(fileName)
            if let data = FileManager.default.contents(atPath: candidate.path) {
                return try ProjectConfig(toml: String(decoding: data, as: UTF8.self), root: dir)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return ProjectConfig(root: fallback) }
            dir = parent
        }
    }
}
