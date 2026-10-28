import Foundation
import PondsideCore
import PondsideTiming

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
    /// The timing rows a canvas compile logged (empty for exports).
    public var timing: TimingLog { TimingLog(parsing: log, prefix: TimingDump.marker) }
    /// LilyPond's own messages, without Pondside's timing rows.
    public var messages: String {
        log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("PONDSIDE-TIMING") }.joined(separator: "\n")
    }
    /// The pages, read from disk, in page order.
    public func pages() -> [EngravedPage] {
        outputFiles.compactMap { try? Data(contentsOf: $0) }.map { EngravedPage(svg: $0) }
    }
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

/// Drives one LilyPond executable. Safe to share.
///
/// Canvas compiles go through a warm `LilyPondDaemon` when one is given
/// (M4), falling back to a fresh process if it fails; exports always use a
/// fresh process.
public struct LilyPondEngraver: Sendable {
    public var installation: LilyPondInstallation
    public var daemon: LilyPondDaemon?

    public init(installation: LilyPondInstallation, daemon: LilyPondDaemon? = nil) {
        self.installation = installation
        self.daemon = daemon
    }

    /// The command-line arguments for a compile. Public so tests can pin the
    /// point-and-click policy without running LilyPond.
    public static func arguments(for purpose: EngravePurpose, source: URL, outputBase: URL,
                                 sessionSettings: URL? = nil) -> [String] {
        var args: [String] = []
        switch purpose {
        case .canvas:
            args += ["-dbackend=svg", "-dpoint-and-click"]
            if let sessionSettings { args.append("-dinclude-settings=\(sessionSettings.path)") }
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
        if case .canvas = purpose, let daemon {
            do {
                return try await daemon.engrave(source, outputDirectory: outputDirectory, extraSettings: TimingDump.listener)
            } catch {
                // A dead or stuck daemon must never cost an engraving.
            }
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = outputDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
        var settings: URL?
        if case .canvas = purpose {
            let url = outputDirectory.appendingPathComponent("pondside-session.ily")
            // Every canvas compile also logs timing, so cue times are always current.
            try Data((SessionSettings.canvas + SessionSettings.fastSVG + TimingDump.listener).utf8).write(to: url)
            settings = url
        }
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await ProcessRunner.run(
            installation.executable,
            Self.arguments(for: purpose, source: source, outputBase: base, sessionSettings: settings),
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

/// Scheme injected into interactive canvas compiles with `-dinclude-settings`.
/// It never touches the user's files, and it is never used for export.
public enum SessionSettings {
    /// Keeps point-and-click on even when a score (or a file it includes)
    /// turns it off. musicxml2ly writes `\pointAndClickOff` at the top of
    /// every file, and `\pointAndClickTypes` restricts which grobs link.
    /// Both go through `ly:set-option`, so wrapping it catches them and any
    /// raw `#(ly:set-option 'point-and-click #f)`: only `#t` gets through.
    /// Verified with LilyPond 2.24.3 (DESIGN.md §7, M2.1).
    /// Idempotent, because the warm daemon reads it once per compile in
    /// one long-lived process: the wrapper is installed only once.
    public static let canvas = """
    #(let ((lily (resolve-module '(lily))))
       (if (not (module-defined? lily 'pondside-original-set-option))
           (let ((original ly:set-option))
             (module-define! lily 'pondside-original-set-option original)
             (set! ly:set-option
                   (lambda (sym . rest)
                     (if (and (eq? sym 'point-and-click) (pair? rest) (not (eq? (car rest) #t)))
                         #f
                         (apply original sym rest)))))))

    """

    /// Makes LilyPond's SVG output several times faster, byte for byte the
    /// same. For every glyph, `output-svg.scm` (2.24) searches the whole
    /// SVG font with a regular expression and copies the font's text; on a
    /// 12-page score that is 15 of 18 seconds. This replaces its
    /// `cache-font` with one that looks the glyph up in a table built once
    /// per font (a linear scan) and remembers each named glyph's result.
    ///
    /// Defensive, since other versions may differ: it installs only if the
    /// procedures it relies on exist, checks its first answers against the
    /// original and switches itself off on any difference, and falls back to
    /// the original on any error. Measured (2.24.3): 18.2 s → 5.1 s.
    public static let fastSVG = """
    #(let ((m (resolve-module '(lily output-svg))))
       (if (and (not (module-defined? m 'pondside-fast-svg))
                (module-defined? m 'cache-font) (module-defined? m 'extract-glyph)
                (module-defined? m 'extract-glyph-info) (module-defined? m 'svg-defs))
           (let ((original (module-ref m 'cache-font))
                 (extract-glyph (module-ref m 'extract-glyph))
                 (extract-glyph-info (module-ref m 'extract-glyph-info))
                 (svg-defs (module-ref m 'svg-defs))
                 (tables (make-hash-table))
                 (paths (make-hash-table))
                 (checked '())
                 (disabled #f))
             (define (table-for font-file)
               (or (hash-ref tables font-file #f)
                   (let ((t (make-hash-table))
                         (defs (svg-defs (cached-file-contents font-file))))
                     (let loop ((from 0))
                       (let ((start (string-contains defs "<glyph" from)))
                         (if start
                             (let ((end (string-contains defs "/>" start)))
                               (if end
                                   (let* ((element (substring defs start (+ end 2)))
                                          (n (string-contains element "glyph-name=\\"")))
                                     (if n
                                         (let* ((a (+ n 12)) (b (string-index element #\\" a)))
                                           (if b (hash-set! t (substring element a b) element))))
                                     (loop (+ end 2))))))))
                     (hash-set! tables font-file t)
                     t)))
             (define (fast svg-font size glyph)
               (let* ((name (if (list? glyph) (car (reverse glyph)) glyph))
                      (element (hash-ref (table-for svg-font) name #f)))
                 (cond ((not element) (original svg-font size glyph))
                       ((list? glyph) (extract-glyph-info element glyph size))
                       (else
                        (let ((key (string-append svg-font "|" name "|" (number->string size))))
                          (or (hash-ref paths key #f)
                              (let ((p (extract-glyph element glyph size)))
                                (hash-set! paths key p)
                                p)))))))
             (module-define! m 'pondside-fast-svg #t)
             (module-set! m 'cache-font
               (lambda (svg-font size glyph)
                 (if disabled
                     (original svg-font size glyph)
                     (catch #t
                       (lambda ()
                         (let ((kind (if (list? glyph) 'string 'named)))
                           (if (memq kind checked)
                               (fast svg-font size glyph)
                               ;; First of its kind: compute both ways (glyph
                               ;; strings move a shared offset, so restore it
                               ;; between the two) and keep the fast way only
                               ;; if they agree.
                               (let* ((adv (module-ref m 'next-horiz-adv))
                                      (a (original svg-font size glyph))
                                      (adv-after (module-ref m 'next-horiz-adv))
                                      (b (begin (module-set! m 'next-horiz-adv adv)
                                                (fast svg-font size glyph))))
                                 (module-set! m 'next-horiz-adv adv-after)
                                 (if (equal? a b)
                                     (set! checked (cons kind checked))
                                     (set! disabled #t))
                                 a))))
                       (lambda args
                         (set! disabled #t)
                         (original svg-font size glyph)))))))))

    """
}
