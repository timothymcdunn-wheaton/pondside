import AppKit
import PondsideCore
import PondsideEngrave
import PondsideBridge
import PondsideTiming

/// The running app over JSON-RPC (docs/API.md): what is open, what is
/// selected, cue times, and events when any of it changes. Scripts and
/// agents that edit the files directly use this to follow along.
@MainActor
final class AppRPC {
    static let shared = AppRPC()
    weak var app: PondsideAppDelegate?
    private var server: RPCSocketServer?
    private(set) var problem: String?

    func start() {
        let server = RPCSocketServer(path: RPCSocketServer.defaultPath) { method, params in
            try await MainActor.run { try AppRPC.shared.handle(method, params) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            problem = "\(error)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func publish(_ event: String, _ params: JSONValue) {
        server?.publish(event, params)
    }

    private var controllers: [DocumentWindowController] { app?.documentControllers ?? [] }

    private func controller(_ params: JSONValue) throws -> DocumentWindowController {
        if let path = params["path"]?.string {
            guard let c = controllers.first(where: { $0.score.file(for: path) != nil }) else {
                throw RPCSocketServer.MethodError("no open score contains \(path)")
            }
            return c
        }
        guard let c = controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.first else {
            throw RPCSocketServer.MethodError("no score is open")
        }
        return c
    }

    func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "app.version":
            return ["name": "Pondside", "version": "0.1.0", "socket": .string(RPCSocketServer.defaultPath)]
        case "app.documents":
            return .array(controllers.map { $0.rpcSummary })
        case "document.text":
            let c = try controller(params)
            let path = params["path"]?.string ?? c.score.root.url.path
            guard let file = c.score.file(for: path) else { throw RPCSocketServer.MethodError("not in the score: \(path)") }
            return ["path": .string(file.url.path), "text": .string(file.text)]
        case "document.selection":
            return try controller(params).rpcSelection
        case "document.select":
            let c = try controller(params)
            guard let path = params["path"]?.string, let line = params["line"]?.int else {
                throw RPCSocketServer.MethodError("document.select needs path, line and character")
            }
            guard c.revealSource(path: path, line: line, character: params["character"]?.int ?? 0) else {
                throw RPCSocketServer.MethodError("can't select \(path):\(line)")
            }
            return c.rpcSelection
        case "document.engrave":
            let c = try controller(params)
            c.score.engrave()
            return ["started": true]
        case "document.cues":
            guard let sheet = try controller(params).score.cueSheet else { return .null }
            return try JSONValue.from(sheet)
        case "document.open":
            guard let path = params["path"]?.string else { throw RPCSocketServer.MethodError("document.open needs a path") }
            app?.open(URL(fileURLWithPath: path))
            return ["opened": .string(path)]
        default:
            throw RPCSocketServer.MethodError(code: -32601, "method not found: \(method)")
        }
    }
}

extension DocumentWindowController {
    var rpcSummary: JSONValue {
        var status: JSONValue
        switch score.status {
        case .idle: status = "idle"
        case .noLilyPond: status = "noLilyPond"
        case .compiling: status = "compiling"
        case .clean: status = "clean"
        case .errors(let n): status = .string("errors:\(n)")
        case .failed(let why): status = .string("failed: \(why)")
        }
        return ["root": .string(score.root.url.path), "files": .array(score.files.map { .string($0.url.path) }),
                "active": .string(activeFile.url.path), "status": status]
    }
}
