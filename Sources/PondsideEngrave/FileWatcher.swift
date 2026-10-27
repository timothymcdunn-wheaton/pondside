import Foundation
import PondsideCore

/// Watches one file for content changes made by any tool.
///
/// Portable by construction: it polls `stat` (cheap) and only reads and
/// hashes the file when size or modification time moves. Polling also copes
/// with atomic-rename saves, which defeat inode-based watchers — and agents
/// and editors save that way constantly. A platform layer may add FSEvents or
/// inotify as a wake-up hint later; this stays the source of truth.
public final class FileWatcher: @unchecked Sendable {
    public struct Change: Sendable {
        public var text: String
        public var hash: ContentHash
    }

    public let url: URL
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "pondside.filewatcher")
    private let onChange: @Sendable (Change) -> Void
    private var timer: DispatchSourceTimer?
    // Mutated only on `queue`.
    private var lastStamp: Stamp?
    private var lastHash: ContentHash?
    private var pollsSinceFullCheck = 0

    /// Size, mtime and inode. File timestamps can be coarser than our poll
    /// interval, so a periodic full content check backs this up.
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }

    /// Every this many polls, hash the file even if the stamp is unchanged.
    private static let fullCheckEvery = 13

    public init(url: URL, interval: DispatchTimeInterval = .milliseconds(150), onChange: @escaping @Sendable (Change) -> Void) {
        self.url = url
        self.interval = interval
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            lastStamp = stamp()
            lastHash = readText().map { ContentHash($0) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Tell the watcher about content we wrote ourselves, so it is not
    /// reported back as an external change.
    public func noteOwnWrite(_ text: String) {
        let hash = ContentHash(text)
        queue.sync { lastHash = hash }
    }

    /// Forces an immediate full check; used by tests and on app activation.
    public func pollNow() {
        queue.sync { poll(force: true) }
    }

    private func poll(force: Bool = false) {
        let current = stamp()
        pollsSinceFullCheck += 1
        let due = force || pollsSinceFullCheck >= Self.fullCheckEvery
        if !due, let current, current == lastStamp { return }
        pollsSinceFullCheck = 0
        lastStamp = current
        guard let text = readText() else { return }
        let hash = ContentHash(text)
        guard hash != lastHash else { return }
        lastHash = hash
        onChange(Change(text: text, hash: hash))
    }

    private func stamp() -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = Self.uint64(attrs[.size]),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Stamp(size: size, modified: modified, inode: Self.uint64(attrs[.systemFileNumber]) ?? 0)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let n = value as? UInt64 { return n }
        if let n = value as? Int { return UInt64(n) }
        return nil
    }

    private func readText() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
