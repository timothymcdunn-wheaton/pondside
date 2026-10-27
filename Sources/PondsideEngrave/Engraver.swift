import Foundation
import PondsideCore

/// What a compile is for. The distinction is a safety property: canvas
/// output embeds absolute source paths for point-and-click; export output
/// must never contain them.
public enum EngravePurpose: Sendable, Equatable {
    /// SVG for the on-screen canvas, with point-and-click links.
    case canvas
    /// Final output for performers and publishers. Point-and-click is off.
    case export(ExportFormat)
}

public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    case pdf, svg, png
}

public struct EngraveResult: Sendable {
    public var outputFiles: [URL]
    public var diagnostics: [Diagnostic]
    public var log: String
    public var exitStatus: Int32
    public var duration: Duration
    public var succeeded: Bool { exitStatus == 0 && !outputFiles.isEmpty }
    public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error || $0.severity == .fatal } }
}

public enum EngraveError: Error, CustomStringConvertible {
    case exportContainsLocalPaths(URL, found: String)

    public var description: String {
        switch self {
        case let .exportContainsLocalPaths(url, found):
            return "refusing to ship \(url.lastPathComponent): it contains a local path or point-and-click link (\(found))"
        }
    }
}

/// Drives one LilyPond executable. Stateless; safe to share.
///
/// M1 spawns a process per compile. M4 replaces this with a persistent
/// daemon holding warm Guile state behind the same interface.
public struct LilyPondEngraver: Sendable {
    public var installation: LilyPondInstallation

    public init(installation: LilyPondInstallation) {
        self.installation = installation
    }

    /// The command-line arguments for a compile. Public so tests can pin the
    /// point-and-click policy without running LilyPond.
    public static func arguments(for purpose: EngravePurpose, source: URL, outputBase: URL) -> [String] {
        var args: [String] = []
        switch purpose {
        case .canvas:
            args += ["-dbackend=svg", "-dpoint-and-click"]
        case .export(let format):
            args += ["-dno-point-and-click"]
            switch format {
            case .pdf: args += ["--pdf"]
            case .svg: args += ["-dbackend=svg"]
            case .png: args += ["--png", "-dresolution=300"]
            }
        }
        args += ["-o", outputBase.path, source.path]
        return args
    }

    /// Compiles `source` into `outputDirectory`, which should be empty or
    /// private to this compile. Pages are returned in page order.
    public func engrave(_ source: URL, purpose: EngravePurpose, outputDirectory: URL) async throws -> EngraveResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = outputDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await ProcessRunner.run(
            installation.executable,
            Self.arguments(for: purpose, source: source, outputBase: base),
            currentDirectory: source.deletingLastPathComponent().path)
        let duration = clock.now - start
        let log = output.stderrString + output.stdoutString

        let ext: String
        switch purpose {
        case .canvas: ext = "svg"
        case .export(let f): ext = f.rawValue
        }
        let files = Self.outputFiles(in: outputDirectory, base: base.lastPathComponent, extension: ext)

        if case .export = purpose {
            for file in files {
                if let leak = try ExportSafety.findLocalPathLeak(in: file, sourceDirectory: source.deletingLastPathComponent().path) {
                    throw EngraveError.exportContainsLocalPaths(file, found: leak)
                }
            }
        }
        return EngraveResult(outputFiles: files, diagnostics: DiagnosticParser.parse(log), log: log,
                             exitStatus: output.status, duration: duration)
    }

    /// LilyPond writes `base.ext` for one page and `base-N.ext` (PNG:
    /// `base-pageN.png`) for several.
    static func outputFiles(in directory: URL, base: String, extension ext: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var pages: [(Int, String)] = []
        for name in names where name.hasSuffix(".\(ext)") {
            let stem = String(name.dropLast(ext.count + 1))
            if stem == base {
                pages.append((0, name))
            } else if stem.hasPrefix(base + "-") {
                // SVG/PDF use base-2; PNG uses base-page2.
                var suffix = stem.dropFirst(base.count + 1)
                if suffix.hasPrefix("page") { suffix = suffix.dropFirst(4) }
                if let n = Int(suffix) { pages.append((n, name)) }
            }
        }
        return pages.sorted { $0.0 < $1.0 }.map { directory.appendingPathComponent($0.1) }
    }
}

/// Defence in depth for the "exported PDFs never contain local paths" rule.
///
/// The primary guarantee is `-dno-point-and-click`. This scan catches a
/// regression in that policy (or a user `\include` that re-enables it). It
/// reads uncompressed bytes only: link annotations are not normally inside
/// compressed object streams, but this is a check, not a proof.
public enum ExportSafety {
    public static func findLocalPathLeak(in file: URL, sourceDirectory: String) throws -> String? {
        let data = try Data(contentsOf: file)
        return findLocalPathLeak(in: [UInt8](data), sourceDirectory: sourceDirectory)
    }

    public static func findLocalPathLeak(in bytes: [UInt8], sourceDirectory: String) -> String? {
        var needles = ["textedit://"]
        // Only flag the directory when it is specific enough to mean something.
        if sourceDirectory.split(separator: "/").count >= 2 { needles.append(sourceDirectory) }
        for needle in needles where contains(bytes, Array(needle.utf8)) {
            return needle
        }
        return nil
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var k = 1
                while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
