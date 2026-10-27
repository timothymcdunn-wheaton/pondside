import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming

// `pondside` — the headless command-line surface. Links only portable
// modules, so it runs on any platform Swift does.

let usage = """
usage: pondside <command> [options]

commands:
  render <file.ly> [--format pdf|svg|png] [--out <dir>] [--json]
      Engrave for export. Point-and-click is always disabled, and the output
      is checked for local filesystem paths before it is written.
  check <file.ly> [--json]
      Compile and report diagnostics. Exit status 1 if there are errors.
  links <file.svg> [--json]
      List the point-and-click links in a canvas SVG with their bounds.
  doctor [--json]
      List every LilyPond installation found, with version and origin.
  cues <file.ly> [--format json|cues] [--rate <hz>] [--out <file>]
      Every \\ecue with its moment, bar, beat, seconds and samples, timed
      exactly as LilyPond's MIDI plays (hidden \\playTempo included).
      --format cues writes the piece.cues lines SuperCollider loaders read.
  handlers <file.ly> --scd <cues.scd> [--project <dir>] [--rate <hz>]
      Create or update a SuperCollider file with one handler per cue. New
      cues get stubs; cues that left the score are commented out; code
      inside a handler is never changed.
  timeline <file.ly> [--json]
      The tempo map: each tempo step's moment, seconds and quarter notes per minute.
  watch <file> --on-change <command>
      Run a shell command whenever the file's content changes.
  version
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, valued: Set<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard let v = it.next() else { throw CLIError("--\(name) needs a value") }
                    options[name] = v
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func resolveLilyPond(for source: URL?) async throws -> LilyPondInstallation {
    let installs = await ToolchainDetector().detectLilyPond()
    let declared = source.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(LilyPondVersion.declared(in:))
    guard let chosen = ToolchainDetector.select(from: installs, for: declared) else {
        throw CLIError("no LilyPond found. Install it (e.g. `brew install lilypond`) or set PONDSIDE_LILYPOND.")
    }
    if let declared, chosen.version != declared {
        printErr("note: score declares \\version \"\(declared)\"; using LilyPond \(chosen.version) at \(chosen.executable)")
    }
    return chosen
}

func sourceURL(_ args: Arguments) throws -> URL {
    guard let path = args.positional.first else { throw CLIError("missing file argument") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError("no such file: \(path)") }
    return url
}

func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct DiagnosticJSON: Encodable {
    var severity: String
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
}

extension DiagnosticJSON {
    init(_ d: Diagnostic) {
        self.init(severity: d.severity.rawValue, message: d.message, file: d.file, line: d.line, column: d.column)
    }
}

func render(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    guard let format = ExportFormat(rawValue: args.options["format"] ?? "pdf") else {
        throw CLIError("unknown format \(args.options["format"]!); expected pdf, svg or png")
    }
    let outDir = URL(fileURLWithPath: args.options["out"] ?? source.deletingLastPathComponent().path).standardizedFileURL
    let engraver = LilyPondEngraver(installation: try await resolveLilyPond(for: source))
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let result = try await engraver.engrave(source, purpose: .export(format), outputDirectory: scratch)
    for d in result.diagnostics { printErr(DiagnosticFormatter.line(d)) }
    guard result.succeeded else {
        printErr("render failed (exit \(result.exitStatus))")
        return 1
    }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var written: [String] = []
    for file in result.outputFiles {
        let dest = outDir.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: file, to: dest)
        written.append(dest.path)
    }
    if args.flags.contains("json") {
        try printJSON(["files": written])
    } else {
        written.forEach { print($0) }
    }
    return 0
}

func check(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let engraver = LilyPondEngraver(installation: try await resolveLilyPond(for: source))
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: scratch)
    if args.flags.contains("json") {
        struct Report: Encodable {
            var ok: Bool
            var pages: Int
            var milliseconds: Int
            var diagnostics: [DiagnosticJSON]
        }
        let ms = Int(result.duration.components.seconds * 1000 + result.duration.components.attoseconds / 1_000_000_000_000_000)
        try printJSON(Report(ok: result.errors.isEmpty && result.succeeded, pages: result.outputFiles.count,
                             milliseconds: ms, diagnostics: result.diagnostics.map(DiagnosticJSON.init)))
    } else {
        for d in result.diagnostics { print(DiagnosticFormatter.line(d)) }
        print(result.errors.isEmpty && result.succeeded ? "clean" : "\(result.errors.count) error(s)")
    }
    return result.errors.isEmpty && result.succeeded ? 0 : 1
}

func links(_ args: Arguments) throws -> Int32 {
    guard let path = args.positional.first else { throw CLIError("missing file argument") }
    let page = EngravedPage(svg: try Data(contentsOf: URL(fileURLWithPath: path)))
    struct Link: Encodable {
        var file: String
        var line: Int
        var character: Int
        var bounds: Rect
    }
    let all = page.graphics.compactMap { g in
        g.link.map { Link(file: $0.path, line: $0.line, character: $0.character, bounds: g.bounds) }
    }
    if args.flags.contains("json") {
        try printJSON(all)
    } else {
        for l in all {
            print("\(l.file):\(l.line):\(l.character)\t\(String(format: "%.2f,%.2f %.2fx%.2f", l.bounds.x, l.bounds.y, l.bounds.width, l.bounds.height))")
        }
    }
    return 0
}

func doctor(_ args: Arguments) async throws -> Int32 {
    let installs = await ToolchainDetector().detectLilyPond()
    if args.flags.contains("json") {
        try printJSON(installs)
    } else if installs.isEmpty {
        print("LilyPond: not found")
    } else {
        for i in installs {
            print("LilyPond \(i.version)\t\(i.origin.rawValue)\t\(i.executable)")
        }
    }
    return installs.isEmpty ? 1 : 0
}

func watch(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    guard let command = args.options["on-change"] else { throw CLIError("watch needs --on-change <command>") }
    let watcher = FileWatcher(url: source) { _ in
        do {
            let out = try ProcessRunner.runBlocking("/bin/sh", ["-c", command])
            FileHandle.standardOutput.write(out.stdout)
            FileHandle.standardError.write(out.stderr)
        } catch {
            printErr("\(error)")
        }
    }
    watcher.start()
    printErr("watching \(source.path) — Ctrl-C to stop")
    while true { try await Task.sleep(for: .seconds(3600)) }
}

func cueSheet(_ args: Arguments) async throws -> CueSheet {
    let source = try sourceURL(args)
    let lily = try await resolveLilyPond(for: source)
    let rate = try args.options["rate"].map { r -> Int in
        guard let v = Int(r), v > 0 else { throw CLIError("--rate needs a sample rate in Hz") }
        return v
    } ?? 48000
    let log = try await TimingDump.run(lily, source: source)
    return CueSheet(log: log, score: source.lastPathComponent, sampleRate: rate)
}

func cues(_ args: Arguments) async throws -> Int32 {
    let sheet = try await cueSheet(args)
    for w in sheet.warnings { printErr("warning: \(w)") }
    let data: Data
    switch args.options["format"] ?? "json" {
    case "json": data = try sheet.json() + Data("\n".utf8)
    case "cues": data = Data(sheet.cuesText.utf8)
    case let f: throw CLIError("unknown format '\(f)' (json, cues)")
    }
    if let out = args.options["out"] {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
    }
    return 0
}

func handlers(_ args: Arguments) async throws -> Int32 {
    guard let scd = args.options["scd"] else { throw CLIError("--scd <file> is required") }
    let sheet = try await cueSheet(args)
    for w in sheet.warnings { printErr("warning: \(w)") }
    let url = URL(fileURLWithPath: scd)
    if let existing = try? String(contentsOf: url, encoding: .utf8) {
        let (text, report) = HandlerSync.sync(existing, with: sheet)
        if text != existing { try Data(text.utf8).write(to: url, options: .atomic) }
        for (what, ids) in [("added", report.added), ("moved", report.moved), ("restored", report.restored),
                            ("commented out", report.orphaned)] where !ids.isEmpty {
            print("\(what): \(ids.joined(separator: ", "))")
        }
        if text == existing { print("\(url.lastPathComponent) is up to date") }
    } else {
        let project = args.options["project"] ?? url.deletingLastPathComponent().path
        try Data(HandlerSync.starter(sheet, projectPath: project).utf8).write(to: url, options: .atomic)
        print("wrote \(url.lastPathComponent) with \(sheet.cues.count) handler stubs")
    }
    return 0
}

func timeline(_ args: Arguments) async throws -> Int32 {
    let sheet = try await cueSheet(args)
    if args.flags.contains("json") {
        try printJSON(sheet.tempo)
    } else {
        for t in sheet.tempo {
            print("\(t.moment)\t" + String(format: "%.3f", t.seconds) + "\t\(t.bpm)")
        }
        if let d = sheet.duration { print("end\t" + String(format: "%.3f", d)) }
    }
    return 0
}

enum DiagnosticFormatter {
    static func line(_ d: Diagnostic) -> String {
        var loc = ""
        if let file = d.file { loc += file }
        if let line = d.line { loc += ":\(line)" }
        if let column = d.column { loc += ":\(column)" }
        return (loc.isEmpty ? "" : loc + ": ") + "\(d.severity.rawValue): \(d.message)"
    }
}

let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
let rest = argv.dropFirst(2)

do {
    let args = try Arguments(rest, valued: ["format", "out", "on-change", "rate", "scd", "project"])
    let status: Int32
    switch command {
    case "render": status = try await render(args)
    case "check": status = try await check(args)
    case "links": status = try links(args)
    case "doctor": status = try await doctor(args)
    case "watch": status = try await watch(args)
    case "cues": status = try await cues(args)
    case "timeline": status = try await timeline(args)
    case "handlers": status = try await handlers(args)
    case "version", "--version": print("pondside 0.1.0 (M1)"); status = 0
    case "help", "--help", "-h": print(usage); status = 0
    default:
        printErr("unknown command '\(command)'\n\n\(usage)")
        status = 2
    }
    exit(status)
} catch {
    printErr("pondside: \(error)")
    exit(1)
}
