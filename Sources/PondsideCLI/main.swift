import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon
import PondsideBridge

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
  lexicon list | show <id> | impl <id> | check <file.ly> | include <file.ly> [--project <dir>]
      The Lexicon in three tiers: list is tier 0 (index.json), show is
      tier 1 (entry.toml and README), impl is tier 2 (the implementation).
      check finds \\lexicon uses with unknown entries or bad params; include
      writes the settings file that defines \\lexicon for a score.
  mockup <file.ly> [--out <file.wav>] [--rate <hz>] [--renderer musescore|fluidsynth] [--soundfont <sf2>]
      Render the score's MIDI (it needs a \\midi block) to audio for the
      patch to play cues against: MuseScore 4 first, fluidsynth as the
      fallback. Silent renders and wrong sample rates are refused.
  completion zsh|bash
      Print a completion script: eval "$(pondside completion zsh)".
  mcp [--project <dir>]
      Serve the Model Context Protocol on stdin/stdout: tools (check, query,
      render, cues, lexicon_check) and the Lexicon tiers as resources.
      Claude Code: claude mcp add pondside -- pondside mcp
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

func lexiconCommand(_ args: Arguments) throws -> Int32 {
    guard let sub = args.positional.first else { throw CLIError("lexicon needs list, show, impl, check or include") }
    let target = args.positional.dropFirst().first
    let scoreDir = target.flatMap { t -> URL? in
        t.hasSuffix(".ly") || t.hasSuffix(".ily") ? URL(fileURLWithPath: t).deletingLastPathComponent() : nil
    }
    let project = args.options["project"].map { URL(fileURLWithPath: $0) } ?? scoreDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let lex = Lexicon.load(Lexicon.standardScopes(project: project))
    for p in lex.problems { printErr("lexicon: \(p)") }
    switch sub {
    case "list":
        print(lex.indexJSON(), terminator: "")
    case "show", "impl":
        guard let id = target else { throw CLIError("lexicon \(sub) needs an entry id") }
        guard let text = sub == "show" ? lex.tier1(id) : lex.tier2(id) else { throw CLIError("no Lexicon entry \(id)") }
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    case "check", "include":
        guard let path = target else { throw CLIError("lexicon \(sub) needs a score") }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        if sub == "check" {
            let problems = lex.check(text)
            for p in problems { print("\(path):\(p.line): \(p.message)") }
            return problems.isEmpty ? 0 : 1
        }
        let used = Set(LexiconUse.find(in: text).map(\.id))
        let out = args.options["out"] ?? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("lexicon.ily").path
        try Data(lex.includeFile(for: used).utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
        print("wrote \(out) for \(used.count) entr\(used.count == 1 ? "y" : "ies")")
    default:
        throw CLIError("unknown lexicon command '\(sub)'")
    }
    return 0
}

func mockup(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let lily = try await resolveLilyPond(for: source)
    let rate = Int(args.options["rate"] ?? "48000") ?? 48000
    let only = try args.options["renderer"].map { r -> MockupRenderer.Renderer in
        guard let v = MockupRenderer.Renderer(rawValue: r) else { throw CLIError("--renderer is musescore or fluidsynth") }
        return v
    }
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let base = scratch.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
    let compile = try await ProcessRunner.run(lily.executable, ["-dno-print-pages", "-o", base.path, source.path],
                                              currentDirectory: source.deletingLastPathComponent().path)
    let midi = ["midi", "mid"].map { base.appendingPathExtension($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    guard let midi else {
        printErr(compile.stderrString.split(separator: "\n").suffix(5).joined(separator: "\n"))
        throw CLIError("no MIDI was written: add \\midi { } to the score you want rendered")
    }
    let out = URL(fileURLWithPath: args.options["out"]
        ?? source.deletingPathExtension().appendingPathExtension("wav").path)
    let renderer = MockupRenderer(sampleRate: rate, soundFont: args.options["soundfont"].map { URL(fileURLWithPath: $0) })
    let (used, info) = try await renderer.render(midi: midi, to: out, only: only)
    print("\(out.path): \(String(format: "%.1f", info.seconds)) s at \(info.sampleRate) Hz via \(used.rawValue), peak \(String(format: "%.1f", 20 * log10(info.peak))) dBFS")
    return 0
}

let completionCommands = ["render", "check", "cues", "timeline", "handlers", "mockup", "lexicon", "links", "doctor", "watch", "mcp",
                          "completion", "version", "help"]

func completion(_ args: Arguments) throws -> Int32 {
    let commands = completionCommands.joined(separator: " ")
    switch args.positional.first {
    case "zsh":
        print("""
        #compdef pondside
        _pondside() {
          local -a commands
          commands=(\(commands))
          if (( CURRENT == 2 )); then
            _describe 'command' commands
          elif [[ $words[2] == lexicon && CURRENT == 3 ]]; then
            _values 'lexicon command' list show impl check include
          elif [[ $words[2] == lexicon && ( $words[3] == show || $words[3] == impl ) ]]; then
            local -a ids
            ids=(${(f)"$(pondside lexicon list 2>/dev/null | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')"})
            _describe 'entry' ids
          elif [[ $words[2] == completion ]]; then
            _values 'shell' zsh bash
          else
            _arguments '*:file:_files -g "*.(ly|ily|svg)"' '--format[output format]:format:(pdf svg png json cues)' \\
              '--out[output path]:path:_files' '--json[JSON output]' '--rate[sample rate]:rate:(44100 48000 96000)' \\
              '--scd[SuperCollider file]:file:_files -g "*.scd"' '--project[project folder]:dir:_files -/'
          fi
        }
        compdef _pondside pondside
        """)
    case "bash":
        print("""
        _pondside() {
          local cur=${COMP_WORDS[COMP_CWORD]}
          if [[ $COMP_CWORD -eq 1 ]]; then
            COMPREPLY=($(compgen -W "\(commands)" -- "$cur"))
          elif [[ ${COMP_WORDS[1]} == lexicon && $COMP_CWORD -eq 2 ]]; then
            COMPREPLY=($(compgen -W "list show impl check include" -- "$cur"))
          elif [[ ${COMP_WORDS[1]} == completion ]]; then
            COMPREPLY=($(compgen -W "zsh bash" -- "$cur"))
          elif [[ $cur == --* ]]; then
            COMPREPLY=($(compgen -W "--format --out --json --rate --scd --project --on-change" -- "$cur"))
          else
            COMPREPLY=($(compgen -f -- "$cur"))
          fi
        }
        complete -o filenames -F _pondside pondside
        """)
    default:
        throw CLIError("completion needs zsh or bash")
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
    let args = try Arguments(rest, valued: ["format", "out", "on-change", "rate", "scd", "project", "renderer", "soundfont"])
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
    case "lexicon": status = try lexiconCommand(args)
    case "completion": status = try completion(args)
    case "mockup": status = try await mockup(args)
    case "mcp":
        let project = URL(fileURLWithPath: args.options["project"] ?? FileManager.default.currentDirectoryPath)
        await MCPServer(project: project).serveStdio()
        status = 0
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
