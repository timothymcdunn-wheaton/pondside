import Foundation
import PondsideCore
import PondsideEngrave

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
    let args = try Arguments(rest, valued: ["format", "out", "on-change"])
    let status: Int32
    switch command {
    case "render": status = try await render(args)
    case "check": status = try await check(args)
    case "links": status = try links(args)
    case "doctor": status = try await doctor(args)
    case "watch": status = try await watch(args)
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
