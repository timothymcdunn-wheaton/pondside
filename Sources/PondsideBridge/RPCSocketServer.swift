import Foundation

/// JSON-RPC 2.0 over a Unix domain socket, one message per line: how the
/// CLI, scripts and agents talk to the running app (document state,
/// selection, edits, engraving), and how they hear about changes.
///
/// Portable: plain POSIX sockets through Foundation. The app supplies the
/// methods; `subscribe` / `unsubscribe` and event delivery live here.
///
///     → {"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["compile.finished"]}}
///     ← {"jsonrpc":"2.0","id":1,"result":{"subscribed":["compile.finished"]}}
///     ← {"jsonrpc":"2.0","method":"compile.finished","params":{…}}
public final class RPCSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// A method error with a JSON-RPC code (the handler's other errors are -32603).
    public struct MethodError: Error {
        public var code: Int
        public var message: String
        public init(code: Int = -32602, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var clients: [Int32: Set<String>] = [:]
    private var running = false

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Where the app listens by default.
    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["PONDSIDE_SOCKET"] { return p }
        #if os(macOS)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pondside")
        #else
        let dir = URL(fileURLWithPath: env["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("pondside")
        #endif
        return dir.appendingPathComponent("pondside.sock").path
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw Failure(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "bind \(path): \(why)")
        }
        // Only this user may connect.
        chmod(path, 0o600)
        lock.lock()
        listener = fd
        running = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listener
        listener = -1
        let open = Array(clients.keys)
        clients = [:]
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        for c in open { shutdown(c, Int32(SHUT_RDWR)); close(c) }
        unlink(path)
    }

    /// Sends an event to every client subscribed to `name` (or to "*").
    public func publish(_ name: String, _ params: JSONValue) {
        let line = JSONValue.object(["jsonrpc": "2.0", "method": .string(name), "params": params]).jsonString() + "\n"
        lock.lock()
        let targets = clients.filter { $0.value.contains(name) || $0.value.contains("*") }.map(\.key)
        lock.unlock()
        for fd in targets { send(line, to: fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            lock.lock()
            let stillRunning = running
            lock.unlock()
            guard stillRunning else { if client >= 0 { close(client) }; return }
            guard client >= 0 else { continue }
            lock.lock()
            clients[client] = []
            lock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let done = DispatchSemaphore(value: 0)
                let reply = LockedReply()
                Task {
                    reply.value = await self.handle(line, client: fd)
                    done.signal()
                }
                done.wait()
                if let r = reply.value { send(r + "\n", to: fd) }
            }
        }
        lock.lock()
        clients[fd] = nil
        lock.unlock()
        close(fd)
    }

    private func send(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        let count = bytes.count
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Synchronous, so the lock is never held across a suspension.
    private func updateSubscriptions(_ client: Int32, adding: Bool, _ names: Set<String>) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if adding { clients[client, default: []].formUnion(names) } else { clients[client]?.subtract(names) }
        return clients[client] ?? []
    }

    func handle(_ line: String, client: Int32) async -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return MCPServer.error(id: .null, code: -32700, message: "parse error").jsonString()
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return MCPServer.error(id: id ?? .null, code: -32600, message: "invalid request").jsonString()
        }
        let params = message["params"] ?? [:]
        let result: JSONValue
        do {
            switch method {
            case "subscribe", "unsubscribe":
                guard case .array(let names)? = params["events"] else { throw MethodError("events: [names]") }
                let now = updateSubscriptions(client, adding: method == "subscribe", Set(names.compactMap(\.string)))
                result = ["subscribed": .array(now.sorted().map { .string($0) })]
            default:
                result = try await handler(method, params)
            }
        } catch let e as MethodError {
            return id.map { MCPServer.error(id: $0, code: e.code, message: e.message).jsonString() }
        } catch {
            return id.map { MCPServer.error(id: $0, code: -32603, message: "\(error)").jsonString() }
        }
        guard let id else { return nil }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
    }
}

private final class LockedReply: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// A minimal client, for the CLI and tests.
public enum RPCClient {
    /// Opens a connection to the app's socket.
    public static func connection(path: String = RPCSocketServer.defaultPath) throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw RPCSocketServer.Failure(description: "socket failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw RPCSocketServer.Failure(description: "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            close(fd)
            throw RPCSocketServer.Failure(description: "Pondside is not running (no socket at \(path))")
        }
        return fd
    }

    public static func send(_ fd: Int32, _ method: String, _ params: JSONValue = [:], id: Int = 1) {
        let request = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            .jsonString() + "\n"
        let out = Array(request.utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress!, out.count) }
    }

    /// Reads one line (one message) from the connection.
    public static func readMessage(_ fd: Int32) throws -> JSONValue {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            line.append(byte)
        }
        guard !line.isEmpty else { throw RPCSocketServer.Failure(description: "connection closed") }
        return try JSONDecoder().decode(JSONValue.self, from: Data(line))
    }

    /// Sends one request and returns its result (or throws its error).
    public static func call(_ method: String, _ params: JSONValue = [:], path: String = RPCSocketServer.defaultPath) throws -> JSONValue {
        let fd = try connection(path: path)
        defer { close(fd) }
        send(fd, method, params)
        let reply = try readMessage(fd)
        if let e = reply["error"] { throw RPCSocketServer.Failure(description: e["message"]?.string ?? "error") }
        return reply["result"] ?? .null
    }
}
