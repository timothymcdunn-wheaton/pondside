import AppKit
import PondsideCore
import PondsideEngrave

enum CompileStatus: Equatable {
    case idle
    case noLilyPond
    case compiling
    case clean(milliseconds: Int)
    case errors(Int)
    case failed(String)
}

@MainActor
protocol ScoreDocumentDelegate: AnyObject {
    func documentDidReloadFromDisk(_ document: ScoreDocument, text: String)
    func documentHasConflict(_ document: ScoreDocument, diskText: String)
    func documentStatusDidChange(_ document: ScoreDocument)
    func documentDidEngrave(_ document: ScoreDocument)
}

/// Detected LilyPond installs, probed once per launch.
@MainActor
final class ToolchainStore {
    static let shared = ToolchainStore()
    private var task: Task<[LilyPondInstallation], Never>?

    func installs() async -> [LilyPondInstallation] {
        if let task { return await task.value }
        let t = Task { await ToolchainDetector().detectLilyPond() }
        task = t
        return await t.value
    }
}

/// Lets a @Sendable callback reach a main-actor object without retaining it.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// One open score: the `.ly` file on disk is the document.
///
/// Edits are autosaved after 250 ms of idle and engraved right after, so
/// the file — not this object — always holds the work. External writes are
/// detected by content, merged into the editor, and re-engraved.
@MainActor
final class ScoreDocument {
    let url: URL
    private(set) var text: String
    /// The parsed text, always in step with `text`.
    private(set) var tree: SyntaxTree
    /// The text the current pages were engraved from (their links refer to it).
    private(set) var engravedText: String?
    /// The text the current diagnostics refer to.
    private(set) var compiledText: String?
    weak var delegate: ScoreDocumentDelegate?

    private(set) var status: CompileStatus = .idle
    private(set) var pages: [EngravedPage] = []
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var installation: LilyPondInstallation?
    private(set) var declaredVersion: LilyPondVersion?
    /// Every source position that produced a graphic, in source order.
    private(set) var linkedPositions: [SourcePosition] = []

    private var sync = DiskSync()
    private var watcher: FileWatcher?
    private var saveTask: Task<Void, Never>?
    private var compileRunning = false
    private var compilePending = false
    private let workDirectory: URL

    static let autosaveDelay: Duration = .milliseconds(250)

    init(url: URL) throws {
        let url = url.standardizedFileURL
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        self.url = url
        text = contents
        tree = SyntaxTree(contents)
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pondside", isDirectory: true)
            .appendingPathComponent(ContentHash(url.path).description, isDirectory: true)
        sync = DiskSync(lastSyncedHash: ContentHash(contents))
        declaredVersion = LilyPondVersion.declared(in: contents)
    }

    func open() {
        let ref = WeakRef(self)
        let w = FileWatcher(url: url) { change in
            Task { @MainActor in ref.value?.diskChanged(change.text) }
        }
        w.start()
        watcher = w
        Task {
            let installs = await ToolchainStore.shared.installs()
            installation = ToolchainDetector.select(from: installs, for: declaredVersion)
            if installation == nil { setStatus(.noLilyPond) } else { engrave() }
        }
    }

    func close() {
        flushPendingSave()
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Re-checks the disk immediately (e.g. when the app becomes active).
    func revalidate() {
        watcher?.pollNow()
    }

    // MARK: Editing and saving

    func userEdited(_ newText: String) {
        text = newText
        tree = SyntaxTree(newText)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: ScoreDocument.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.save()
            self.engrave()
        }
    }

    func flushPendingSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        saveTask = nil
        guard ContentHash(text) != sync.lastSyncedHash else { return }
        do {
            watcher?.noteOwnWrite(text)
            try Data(text.utf8).write(to: url, options: .atomic)
            sync.noteSynced(text)
            declaredVersion = LilyPondVersion.declared(in: text)
        } catch {
            setStatus(.failed("Could not save: \(error.localizedDescription)"))
        }
    }

    /// Resolve a conflict in favour of the buffer or the disk. The losing
    /// side is kept in a recovery file — never discarded.
    func resolveConflict(keepMine: Bool, diskText: String) {
        if keepMine {
            stashRecovery(diskText, label: "disk")
            sync.noteSynced(diskText)
            saveTask?.cancel()
            save()
        } else {
            stashRecovery(text, label: "unsaved")
            adopt(diskText)
            delegate?.documentDidReloadFromDisk(self, text: diskText)
        }
        engrave()
    }

    private func diskChanged(_ diskText: String) {
        switch sync.classify(diskText: diskText, bufferText: text) {
        case .ignore:
            sync.noteSynced(diskText)
        case .reload:
            adopt(diskText)
            delegate?.documentDidReloadFromDisk(self, text: diskText)
            engrave()
        case .conflict:
            delegate?.documentHasConflict(self, diskText: diskText)
        }
    }

    private func adopt(_ diskText: String) {
        saveTask?.cancel()
        saveTask = nil
        text = diskText
        tree = SyntaxTree(diskText)
        sync.noteSynced(diskText)
        declaredVersion = LilyPondVersion.declared(in: diskText)
    }

    private func stashRecovery(_ contents: String, label: String) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("Pondside/Recovery", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(url.deletingPathExtension().lastPathComponent)-\(label)-\(stamp).ly"
        try? Data(contents.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Engraving

    /// Compiles the file on disk. Compiles never overlap; requests that
    /// arrive mid-compile collapse into one follow-up compile.
    func engrave() {
        guard let installation else { return }
        if compileRunning {
            compilePending = true
            return
        }
        compileRunning = true
        setStatus(.compiling)
        let engraver = LilyPondEngraver(installation: installation)
        let source = url
        // Exactly what LilyPond will read, so links and diagnostics can be
        // mapped back onto text that has moved on since.
        let snapshot = (try? String(contentsOf: url, encoding: .utf8)) ?? text
        let out = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task {
            var outcome = await Self.compile(engraver, source: source, out: out)
            outcome.snapshot = snapshot
            self.finish(outcome)
        }
    }

    private struct Outcome: Sendable {
        var result: EngraveResult?
        var pages: [EngravedPage]
        var error: String?
        var snapshot = ""
    }

    /// Runs off the main actor: the compile and the SVG parsing.
    nonisolated private static func compile(_ engraver: LilyPondEngraver, source: URL, out: URL) async -> Outcome {
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: out)
            let pages = result.outputFiles.compactMap { try? Data(contentsOf: $0) }.map { EngravedPage(svg: $0) }
            return Outcome(result: result, pages: pages, error: nil)
        } catch {
            return Outcome(result: nil, pages: [], error: String(describing: error))
        }
    }

    private func finish(_ outcome: Outcome) {
        compileRunning = false
        if let result = outcome.result {
            compiledText = outcome.snapshot
            diagnostics = result.diagnostics.filter { d in
                guard let file = d.file else { return true }
                return PathMatching.same(file, url.path) || file == url.lastPathComponent
            }
            // Keep showing the last good engraving while the source has errors,
            // so the score never blanks out mid-thought.
            if !outcome.pages.isEmpty {
                pages = outcome.pages
                engravedText = outcome.snapshot
                linkedPositions = Self.positions(in: pages)
            }
            let errorCount = result.errors.count
            if errorCount > 0 {
                setStatus(.errors(errorCount))
            } else if !result.succeeded {
                setStatus(.failed("LilyPond exited with status \(result.exitStatus)"))
            } else {
                let c = result.duration.components
                setStatus(.clean(milliseconds: Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)))
            }
            delegate?.documentDidEngrave(self)
        } else {
            setStatus(.failed(outcome.error ?? "unknown error"))
        }
        if compilePending {
            compilePending = false
            engrave()
        }
    }

    private static func positions(in pages: [EngravedPage]) -> [SourcePosition] {
        var set = Set<SourcePosition>()
        for page in pages {
            for g in page.graphics { if let l = g.link { set.insert(l.position) } }
        }
        return set.sorted()
    }

    private func setStatus(_ s: CompileStatus) {
        status = s
        delegate?.documentStatusDidChange(self)
    }

    // MARK: Export

    /// Engraves a PDF for distribution — point-and-click off, leak-checked —
    /// and moves it to `destination`.
    func exportPDF(to destination: URL) async throws {
        flushPendingSave()
        guard let installation else { throw CocoaError(.featureUnsupported) }
        let engraver = LilyPondEngraver(installation: installation)
        let out = workDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await engraver.engrave(url, purpose: .export(.pdf), outputDirectory: out)
        guard result.succeeded, let pdf = result.outputFiles.first else {
            throw NSError(domain: "Pondside", code: 1, userInfo: [NSLocalizedDescriptionKey: result.errors.first?.message ?? "LilyPond failed"])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: pdf, to: destination)
    }
}
