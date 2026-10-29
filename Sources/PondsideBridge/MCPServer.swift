import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon

/// Pondside as an MCP server (stdio transport: one JSON-RPC message per
/// line). Tools are the headless half of the app — check, render, query,
/// cues, Lexicon checks — and the Lexicon's three tiers are resources, so
/// progressive disclosure happens by construction (DESIGN.md §3).
///
/// Vendor-neutral: any MCP client can launch `pondside mcp`.
public actor MCPServer {
    public static let serverName = "pondside"
    public static let serverVersion = "0.1.0"
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Where `\lexicon` resources come from: the standard scopes plus the
    /// project folder (the working directory unless told otherwise).
    let project: URL

    public init(project: URL) {
        self.project = project
    }

    // MARK: Transport

    /// Reads requests from stdin until it closes, answering each on stdout.
    public func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// One message in, at most one message out (notifications get none).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return Self.error(id: .null, code: -32700, message: "parse error").jsonString()
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return id == nil ? nil : Self.error(id: id ?? .null, code: -32600, message: "invalid request").jsonString()
        }
        let params = message["params"] ?? .object([:])
        do {
            let result = try await dispatch(method, params)
            guard let id else { return nil }
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
        } catch let e as RPCError {
            guard let id else { return nil }
            return Self.error(id: id, code: e.code, message: e.message).jsonString()
        } catch {
            guard let id else { return nil }
            return Self.error(id: id, code: -32603, message: "\(error)").jsonString()
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    // MARK: Methods

    func dispatch(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.supportedProtocols[0]
            let version = Self.supportedProtocols.contains(asked) ? asked : Self.supportedProtocols[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion)],
                "instructions": """
                Pondside scores are plain LilyPond files: read and edit them directly. Use these tools to \
                check that a score compiles (check), list its notes with exact positions (query), render it, \
                time its electronics cues (cues), and validate \\lexicon uses. Browse the Lexicon through \
                resources: lexicon://index first (one line per entry), then lexicon://entry/{id}, and \
                lexicon://impl/{id} only when adapting an implementation. For graphic notation (textures, \
                grains, ripples, wedges, swells, contours) read the skill lexicon://guide/graphics first and \
                follow it: score_context to learn what "here" means, lexicon_search, graphic_preview, \
                graphic_insert. Only if the user rejects every combination of existing entries, read \
                lexicon://guide/entries and write a new entry with lexicon_propose (a draft the user accepts).
                """,
            ]
        case "ping", "notifications/initialized", "notifications/cancelled":
            return [:]
        case "tools/list":
            return ["tools": .array(Self.tools.map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.string else { throw RPCError(code: -32602, message: "tools/call needs a name") }
            let args = params["arguments"] ?? [:]
            do {
                let text = try await callTool(name, args)
                return ["content": [["type": "text", "text": .string(text)]], "isError": false]
            } catch let e as RPCError {
                throw e
            } catch {
                // Tool failures are results the model should see, not protocol errors.
                return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
            }
        case "prompts/list":
            return ["prompts": .array(Self.skills.map { s in
                ["name": .string(s.prompt), "description": .string(s.description)]
            })]
        case "prompts/get":
            guard let name = params["name"]?.string, let skill = Self.skills.first(where: { $0.prompt == name }),
                  let text = Self.skillText(skill) else {
                throw RPCError(code: -32602, message: "unknown prompt")
            }
            return ["description": .string(skill.description),
                    "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
        case "resources/list":
            let lex = lexicon()
            var list: [JSONValue] = [
                ["uri": "lexicon://index", "name": "Lexicon index", "mimeType": "application/json",
                 "description": "Tier 0: every entry's id, gloss, tags and param names, one line each"],
            ]
            for s in Self.skills {
                list.append(["uri": .string(s.uri), "name": .string(s.prompt), "mimeType": "text/markdown",
                             "description": .string(s.description)])
            }
            for id in lex.ids {
                list.append(["uri": .string("lexicon://entry/\(id)"), "name": .string(id), "mimeType": "text/markdown",
                             "description": .string(lex.entries[id]?.entry.gloss ?? "")])
            }
            return ["resources": .array(list)]
        case "resources/templates/list":
            return ["resourceTemplates": [
                ["uriTemplate": "lexicon://entry/{id}", "name": "Lexicon entry (tier 1)", "mimeType": "text/markdown"],
                ["uriTemplate": "lexicon://impl/{id}", "name": "Lexicon implementation (tier 2)", "mimeType": "text/x-lilypond"],
            ]]
        case "resources/read":
            guard let uri = params["uri"]?.string else { throw RPCError(code: -32602, message: "resources/read needs a uri") }
            let (text, mime) = try readResource(uri)
            return ["contents": [["uri": .string(uri), "mimeType": .string(mime), "text": .string(text)]]]
        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    func lexicon() -> Lexicon {
        Lexicon.load(Lexicon.standardScopes(project: project))
    }

    func readResource(_ uri: String) throws -> (String, String) {
        let lex = lexicon()
        if uri == "lexicon://index" { return (lex.indexJSON(), "application/json") }
        if let skill = Self.skills.first(where: { $0.uri == uri }), let text = Self.skillText(skill) {
            return (text, "text/markdown")
        }
        for (prefix, tier) in [("lexicon://entry/", 1), ("lexicon://impl/", 2)] where uri.hasPrefix(prefix) {
            let id = String(uri.dropFirst(prefix.count))
            if let text = tier == 1 ? lex.tier1(id) : lex.tier2(id) {
                return (text, tier == 1 ? "text/markdown" : "text/x-lilypond")
            }
            throw RPCError(code: -32002, message: "no Lexicon entry \(id)")
        }
        throw RPCError(code: -32002, message: "unknown resource \(uri)")
    }

    // MARK: Skills

    /// The two skills of DESIGN.md §7: the high-level one for working with
    /// the Lexicon's graphic entries, and the low-level one for writing new
    /// entries when those aren't enough.
    struct Skill {
        var folder: String
        var uri: String
        var prompt: String
        var description: String
    }

    static let skills = [
        Skill(folder: "graphic-notation", uri: "lexicon://guide/graphics", prompt: "graphic-notation",
              description: "Graphic notation with the Lexicon: find \"here\", choose and combine graphic entries, preview, insert"),
        Skill(folder: "lexicon-entries", uri: "lexicon://guide/entries", prompt: "lexicon-entries",
              description: "Writing new Lexicon entries: the graphics kit, the entry folder, LilyPond and Guile gotchas, checks"),
    ]

    static func skillText(_ s: Skill) -> String? {
        guard let core = Lexicon.coreDirectory else { return nil }
        return try? String(contentsOf: core.appendingPathComponent("Skills/\(s.folder)/SKILL.md"), encoding: .utf8)
    }

    // MARK: Tools

    struct Tool {
        var name: String
        var description: String
        var properties: [String: JSONValue]
        var required: [String]

        var json: JSONValue {
            ["name": .string(name), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties),
                             "required": .array(required.map { .string($0) })]]
        }
    }

    static let file: JSONValue = ["type": "string", "description": "Path to a .ly file (absolute, or relative to the server's directory)"]

    static let tools: [Tool] = [
        Tool(name: "check", description: "Compile a score with LilyPond and return its diagnostics (file, line, column, message). Truth comes from LilyPond itself.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "query", description: "List a score's musical events in order: kind, absolute pitches (Dutch names, c' = middle C), duration, and source line:character, for precise edits.",
             properties: ["file": file,
                          "from_line": ["type": "integer", "description": "First source line to include"],
                          "to_line": ["type": "integer", "description": "Last source line to include"]],
             required: ["file"]),
        Tool(name: "render", description: "Engrave a score for export (PDF, SVG or PNG) with point-and-click disabled. Returns the written files.",
             properties: ["file": file, "format": ["type": "string", "enum": ["pdf", "svg", "png"]],
                          "out": ["type": "string", "description": "Output directory (default: beside the score)"]],
             required: ["file"]),
        Tool(name: "cues", description: "Every electronics cue (\\ecue, and Lexicon entries with sounds) with moment, bar, beat, seconds and samples, timed exactly as the MIDI plays.",
             properties: ["file": file, "rate": ["type": "integer", "description": "Sample rate (default 48000)"]],
             required: ["file"]),
        Tool(name: "lexicon_check", description: "Check a score's \\lexicon and \\startGraphic uses against the Lexicon: unknown entries, unknown params, values out of range.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "score_context", description: "What \"here\" means: the event at a point (or the user's click or selection in the running Pondside app), its staff's .ly, its bar, any graphic it is in (entry and params), and, from the app, the first and last events of its system and the first of the next system. Call this before placing anything.",
             properties: ["file": file,
                          "line": ["type": "integer", "description": "1-based line (omit to use the app's selection)"],
                          "character": ["type": "integer", "description": "0-based character on the line"]],
             required: []),
        Tool(name: "lexicon_search", description: "Find Lexicon entries for a description (\"grainy texture\", \"ripple\", \"wedge\"): tier 0 lines, best first.",
             properties: ["query": ["type": "string"], "limit": ["type": "integer"]], required: ["query"]),
        Tool(name: "lexicon_entry", description: "One entry's params (types, ranges, defaults, docs) and README pitfalls: tier 1.",
             properties: ["id": ["type": "string"]], required: ["id"]),
        Tool(name: "graphic_preview", description: "Engrave a graphic entry with given params over a span of bars on its own staff and return the SVG's path, to look at before inserting.",
             properties: ["id": ["type": "string"],
                          "params": ["type": "string", "description": "Scheme alist, e.g. ((height . (swell 3 0.5 4)) (seed . 2))"],
                          "bars": ["type": "integer", "description": "Span length in 4/4 bars (default 4)"],
                          "music": ["type": "string", "description": "Optional LilyPond for a staff above, e.g. the passage's music"],
                          "out": ["type": "string", "description": "Directory for the SVG (default: a temporary one)"]],
             required: ["id"]),
        Tool(name: "graphic_insert", description: "Insert a graphic as a minimal edit: \\startGraphic on the event at start, \\stopGraphic on the event at stop (same staff), then write lexicon.ily and include it in the root.",
             properties: ["file": file, "id": ["type": "string"], "params": ["type": "string", "description": "Scheme alist"],
                          "start_line": ["type": "integer"], "start_character": ["type": "integer"],
                          "stop_line": ["type": "integer"], "stop_character": ["type": "integer"],
                          "root": ["type": "string", "description": "The score's root file, if not `file`"]],
             required: ["file", "id", "start_line", "start_character", "stop_line", "stop_character"]),
        Tool(name: "lexicon_propose", description: "Write a new entry as a draft in the project's Lexicon/drafts/ (validated; usable in the score at once). The user accepts or rejects it; never promote it yourself.",
             properties: ["id": ["type": "string"], "entry_toml": ["type": "string"], "impl": ["type": "string"],
                          "readme": ["type": "string"]],
             required: ["id", "entry_toml", "impl", "readme"]),
    ]

    func path(_ args: JSONValue) throws -> URL {
        guard let f = args["file"]?.string else { throw RPCError(code: -32602, message: "missing argument: file") }
        let url = f.hasPrefix("/") ? URL(fileURLWithPath: f) : project.appendingPathComponent(f)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolFailure("no such file: \(url.path)") }
        return url.standardizedFileURL
    }

    struct ToolFailure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    func lilypond(for source: URL) async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        let declared = (try? String(contentsOf: source, encoding: .utf8)).flatMap(LilyPondVersion.declared(in:))
        guard let lily = ToolchainDetector.select(from: installs, for: declared) else {
            throw ToolFailure("LilyPond is not installed (brew install lilypond)")
        }
        return lily
    }

    func callTool(_ name: String, _ args: JSONValue) async throws -> String {
        switch name {
        case "check":
            let source = try path(args)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mcp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = try await LilyPondEngraver(installation: try await lilypond(for: source))
                .engrave(source, purpose: .canvas, outputDirectory: scratch)
            // Pondside's own canvas options aren't the score's problems.
            let diagnostics: [JSONValue] = result.diagnostics.filter { !$0.message.hasPrefix("ignoring unsupported formats") }.map { d -> JSONValue in
                let file: JSONValue = d.file.map(JSONValue.string) ?? .null
                let line: JSONValue = d.line.map { JSONValue.number(Double($0)) } ?? .null
                let column: JSONValue = d.column.map { JSONValue.number(Double($0)) } ?? .null
                return ["severity": .string(d.severity.rawValue), "file": file, "line": line, "column": column,
                        "message": .string(d.message)]
            }
            let ok = result.errors.isEmpty && result.succeeded
            return JSONValue.object(["ok": .bool(ok), "pages": .number(Double(result.outputFiles.count)),
                                     "diagnostics": .array(diagnostics)]).jsonString(pretty: true)
        case "query":
            let source = try path(args)
            let text = try String(contentsOf: source, encoding: .utf8)
            return ScoreQuery.events(in: text, fromLine: args["from_line"]?.int, toLine: args["to_line"]?.int)
                .jsonString(pretty: true)
        case "render":
            let source = try path(args)
            guard let format = ExportFormat(rawValue: args["format"]?.string ?? "pdf") else { throw ToolFailure("format must be pdf, svg or png") }
            let out = args["out"]?.string.map { URL(fileURLWithPath: $0) } ?? source.deletingLastPathComponent()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mcp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = try await LilyPondEngraver(installation: try await lilypond(for: source))
                .engrave(source, purpose: .export(format), outputDirectory: scratch)
            guard result.succeeded else {
                throw ToolFailure("render failed:\n" + result.diagnostics.map { "\($0.line.map(String.init) ?? "?"): \($0.message)" }.joined(separator: "\n"))
            }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var written: [JSONValue] = []
            for f in result.outputFiles {
                let dest = out.appendingPathComponent(f.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: f, to: dest)
                written.append(.string(dest.path))
            }
            return JSONValue.object(["files": .array(written)]).jsonString(pretty: true)
        case "cues":
            let source = try path(args)
            let log = try await TimingDump.run(try await lilypond(for: source), source: source)
            let lex = Lexicon.load(Lexicon.standardScopes(project: source.deletingLastPathComponent()))
            let sheet = CueSheet(log: log, score: source.lastPathComponent, sampleRate: args["rate"]?.int ?? 48000,
                                 soundParams: { lex.soundParams(entry: $0, params: $1, beatDur: $2, spanDur: $3, tempo: $4) })
            return String(decoding: try sheet.json(), as: UTF8.self)
        case "lexicon_check":
            let source = try path(args)
            let problems = lexicon().check(try String(contentsOf: source, encoding: .utf8))
            if problems.isEmpty { return "No problems: every \\lexicon use names a known entry with valid params." }
            return problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
        case "score_context":
            if let f = args["file"]?.string, let line = args["line"]?.int {
                let source = try path(["file": .string(f)])
                let text = try String(contentsOf: source, encoding: .utf8)
                var context = ScoreContext.describe(text: text, file: source.path, line: line, character: args["character"]?.int ?? 0)
                // The app knows the system; ask it when it is running.
                if let app = try? RPCClient.call("document.context", ["path": .string(source.path), "line": .number(Double(line)),
                                                                               "character": .number(Double(args["character"]?.int ?? 0))]),
                   case .object(var o) = context, let system = app["system"] {
                    o["system"] = system
                    context = .object(o)
                }
                return context.jsonString(pretty: true)
            }
            do {
                return try RPCClient.call("document.context", [:]).jsonString(pretty: true)
            } catch {
                throw ToolFailure("Pondside isn't running, so there is no selection: pass file and line")
            }
        case "lexicon_search":
            let lines = lexicon().search(args["query"]?.string ?? "", limit: args["limit"]?.int ?? 8)
            return lines.isEmpty ? "No entries match. Try other words, or lexicon://index for all." : lines.joined(separator: "\n")
        case "lexicon_entry":
            guard let id = args["id"]?.string, let text = lexicon().tier1(id) else { throw ToolFailure("no Lexicon entry \(args["id"]?.string ?? "")") }
            return text
        case "graphic_preview":
            return try await preview(args)
        case "graphic_insert":
            let source = try path(args)
            guard let id = args["id"]?.string, lexicon().entries[id] != nil else { throw ToolFailure("no Lexicon entry \(args["id"]?.string ?? "")") }
            let text = try String(contentsOf: source, encoding: .utf8)
            let new = try GraphicEdit.insert(into: text, id: id, params: args["params"]?.string ?? "()",
                                             start: (args["start_line"]?.int ?? 0, args["start_character"]?.int ?? 0),
                                             stop: (args["stop_line"]?.int ?? 0, args["stop_character"]?.int ?? 0))
            let problems = lexicon().check(new)
            guard problems.isEmpty else {
                throw ToolFailure(problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n"))
            }
            try Data(new.utf8).write(to: source, options: .atomic)
            let root = try args["root"]?.string.map { try path(["file": .string($0)]) } ?? source
            let include = try GraphicEdit.prepareLexiconInclude(root: root, lexicon: lexicon())
            return "Inserted \(id) in \(source.lastPathComponent); wrote \(include.lastPathComponent). Compile with check to confirm."
        case "lexicon_propose":
            guard let id = args["id"]?.string else { throw ToolFailure("missing id") }
            let dir = try Lexicon.propose(id: id, toml: args["entry_toml"]?.string ?? "", impl: args["impl"]?.string ?? "",
                                          readme: args["readme"]?.string ?? "", project: project)
            return "Draft written to \(dir.path). Preview it with graphic_preview, show the user, and let them accept it (pondside lexicon promote \(id)) or reject it."
        default:
            throw RPCError(code: -32602, message: "unknown tool: \(name)")
        }
    }

    /// A graphic on its own staff over `bars` bars, engraved to SVG.
    func preview(_ args: JSONValue) async throws -> String {
        guard let id = args["id"]?.string else { throw ToolFailure("missing id") }
        let lex = lexicon()
        guard lex.entries[id] != nil else { throw ToolFailure("no Lexicon entry \(id)") }
        let bars = max(1, min(32, args["bars"]?.int ?? 4))
        let params = args["params"]?.string ?? "()"
        let dir = args["out"]?.string.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pondside-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(lex.includeFile(for: [id]).utf8).write(to: dir.appendingPathComponent("lexicon.ily"), options: .atomic)
        guard let entry = lex.entries[id]?.entry else { throw ToolFailure("no Lexicon entry \(id)") }
        let score = GraphicEdit.previewSource(entry: entry, params: params, bars: bars, music: args["music"]?.string)
        let file = dir.appendingPathComponent("preview.ly")
        try Data(score.utf8).write(to: file, options: .atomic)
        let lily = try await lilypond(for: file)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .export(.svg), outputDirectory: dir.appendingPathComponent("svg"))
        let problems = result.diagnostics.filter { $0.severity != .warning || $0.file?.hasSuffix("preview.ly") == true }
            .map { "\($0.severity.rawValue) \($0.line.map(String.init) ?? "?"): \($0.message)" }
        guard result.succeeded else { throw ToolFailure("preview failed:\n" + problems.joined(separator: "\n")) }
        return JSONValue.object(["svg": .array(result.outputFiles.map { .string($0.path) }),
                                 "source": .string(file.path),
                                 "diagnostics": .array(problems.map { .string($0) })]).jsonString(pretty: true)
    }
}
