import Foundation
import XCTest
@testable import PondsideBridge

final class RPCSocketTests: XCTestCase {
    func testCallsSubscriptionsAndEvents() throws {
        // Unix socket paths are short: keep it in /tmp.
        let path = "/tmp/pondside-test-\(UUID().uuidString.prefix(8)).sock"
        let server = RPCSocketServer(path: path) { method, params in
            switch method {
            case "echo": return params
            case "fail": throw RPCSocketServer.MethodError("bad params")
            default: throw RPCSocketServer.MethodError(code: -32601, "method not found: \(method)")
            }
        }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(try RPCClient.call("echo", ["x": 1], path: path), ["x": 1])
        XCTAssertThrowsError(try RPCClient.call("fail", path: path)) { XCTAssertTrue("\($0)".contains("bad params")) }
        XCTAssertThrowsError(try RPCClient.call("nope", path: path))

        let fd = try RPCClient.connection(path: path)
        defer { close(fd) }
        RPCClient.send(fd, "subscribe", ["events": ["compile.finished"]])
        XCTAssertEqual(try RPCClient.readMessage(fd)["result"]?["subscribed"], ["compile.finished"])
        server.publish("score.changed", ["file": "a.ly"])          // not subscribed: not delivered
        server.publish("compile.finished", ["ok": true])
        let event = try RPCClient.readMessage(fd)
        XCTAssertEqual(event["method"], "compile.finished")
        XCTAssertEqual(event["params"]?["ok"], true)
        XCTAssertNil(event["id"], "events are notifications")
    }

    func testOnlyTheUserCanConnect() throws {
        let path = "/tmp/pondside-test-\(UUID().uuidString.prefix(8)).sock"
        let server = RPCSocketServer(path: path) { _, p in p }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
