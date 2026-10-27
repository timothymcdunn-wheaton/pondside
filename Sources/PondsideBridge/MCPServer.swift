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
                "capabilities": ["tools": [:], "resources": [:]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion)],
                "instructions": """
                Pondside scores are plain LilyPond files: read and edit them directly. Use these tools to \
                check that a score compiles (check), list its notes with exact positions (query), render it, \
                time its electronics cues (cues), and validate \\lexicon uses. Browse the Lexicon through \
                resources: lexicon://index first (one line per entry), then lexicon://entry/{id}, and \
                lexicon://impl/{id} only when adapting an implementation.
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
        case "resources/list":
            let lex = lexicon()
            var list: [JSONValue] = [
                ["uri": "lexicon://index", "name": "Lexicon index", "mimeType": "application/json",
                 "description": "Tier 0: every entry's id, gloss, tags and param names, one line each"],
            ]
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
        for (prefix, tier) in [("lexicon://entry/", 1), ("lexicon://impl/", 2)] where uri.hasPrefix(prefix) {
            let id = String(uri.dropFirst(prefix.count))
            if let text = tier == 1 ? lex.tier1(id) : lex.tier2(id) {
                return (text, tier == 1 ? "text/markdown" : "text/x-lilypond")
            }
            throw RPCError(code: -32002, message: "no Lexicon entry \(id)")
        }
        throw RPCError(code: -32002, message: "unknown resource \(uri)")
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
        Tool(name: "lexicon_check", description: "Check a score's \\lexicon uses against the Lexicon: unknown entries, unknown params, values out of range.",
             properties: ["file": file], required: ["file"]),
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
            let diagnostics: [JSONValue] = result.diagnostics.map { d -> JSONValue in
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
            let sheet = CueSheet(log: log, score: source.lastPathComponent, sampleRate: args["rate"]?.int ?? 48000)
            return String(decoding: try sheet.json(), as: UTF8.self)
        case "lexicon_check":
            let source = try path(args)
            let problems = lexicon().check(try String(contentsOf: source, encoding: .utf8))
            if problems.isEmpty { return "No problems: every \\lexicon use names a known entry with valid params." }
            return problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
        default:
            throw RPCError(code: -32602, message: "unknown tool: \(name)")
        }
    }
}
