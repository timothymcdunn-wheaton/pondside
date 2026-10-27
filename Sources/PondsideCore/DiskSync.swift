/// Decides what to do when the file on disk and the in-memory buffer diverge.
///
/// The `.ly` file is the single source of truth and any tool may write it at
/// any time. Pondside writes it too (debounced autosave), so the watcher sees
/// our own writes; this type tells them apart from foreign ones by content
/// hash rather than by timestamps, which are unreliable across tools.
public struct DiskSync: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Disk matches what we last wrote or read: nothing to do.
        case ignore
        /// Foreign change and no unsaved local edits: adopt the disk text.
        case reload
        /// Foreign change while local edits are unsaved.
        case conflict
    }

    /// Hash of the content we last wrote to, or read from, disk.
    public private(set) var lastSyncedHash: ContentHash?

    public init(lastSyncedHash: ContentHash? = nil) {
        self.lastSyncedHash = lastSyncedHash
    }

    public mutating func noteSynced(_ text: String) {
        lastSyncedHash = ContentHash(text)
    }

    public func classify(diskText: String, bufferText: String) -> Decision {
        let disk = ContentHash(diskText)
        if disk == lastSyncedHash { return .ignore }
        if diskText == bufferText { return .ignore }
        let bufferIsClean = ContentHash(bufferText) == lastSyncedHash
        return bufferIsClean ? .reload : .conflict
    }
}
