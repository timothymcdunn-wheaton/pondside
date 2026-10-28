import Foundation

/// A warm LilyPond: one long-lived process that compiles canvas SVGs on
/// request, so each edit pays for engraving, not for starting Guile.
///
/// LilyPond already compiles several files in one run, resetting its
/// session between them. The daemon drives that loop from stdin: a `-e`
/// expression loads `script` into the `(lily)` module, initialises the
/// session once, then for each request runs the per-file half of
/// `lilypond-all`. Measured on 2.24.3 (DESIGN.md, M4): the first compile
/// pays the ~3 s start, and later ones take 0.2–0.4 s in CI-class Linux
/// containers, against 3.3–3.5 s cold.
///
/// The working directory is the score's folder, as in a cold compile
/// (Scheme `load` resolves from there), and output goes to the job's
/// folder through `\paper { output-filename = … }`. Canvas only: export
/// always uses a fresh process with point-and-click off.
public actor LilyPondDaemon {
    public let installation: LilyPondInstallation
    /// Restart after this many compiles to bound memory growth.
    public var maxJobs = 150
    /// A compile taking longer than this is presumed stuck; the process is
    /// killed and restarted.
    public var timeout: Duration = .seconds(120)

    private var process: Process?
    private var input: FileHandle?
    private var pipe: DaemonPipe?
    private var jobs = 0
    private var scriptURL: URL?
    private var dispatcherURL: URL?

    public init(installation: LilyPondInstallation) {
        self.installation = installation
    }

    static let marker = "PONDSIDE-DONE "

    /// Included by every job through `include-settings`, it includes that
    /// job's own settings file. In 2.26 the option is an append-only list
    /// that `ly:set-option` refuses to change, so it is registered once, at
    /// start, and the loop names each job's file in `pondside-job-settings`.
    static let dispatcher = """
    #(ly:parser-include-string (format #f "\\\\include \\\"~a\\\"" (module-ref (resolve-module '(lily)) 'pondside-job-settings)))

    """

    /// The loop LilyPond runs. Requests are `<source>\t<settings file>\n`.
    /// It expects `pondside-dispatcher` to name a file holding `dispatcher`.
    static let script = """
    (use-modules (ice-9 rdelim))
    ; One ordered stream: a score's own output stays with its job.
    (set-current-output-port (current-error-port))
    (ly:reset-all-fonts)
    (ly:parse-init "declarations-init.ly")
    ; 2.24: a string option; 2.26: an accumulative list.
    (if (list? (ly:get-option 'include-settings))
        (ly:append-to-option 'include-settings pondside-dispatcher)
        (ly:set-option 'include-settings pondside-dispatcher))
    (define pondside-job-settings #f)
    (display "\\nPONDSIDE-DONE ready\\n" (current-error-port))
    (force-output (current-error-port))
    (let loop ()
      (let ((line (read-line (current-input-port))))
        (if (eof-object? line) (ly:exit 0 #f))
        (let* ((parts (string-split line #\\tab))
               (file (car parts))
               (settings (cadr parts))
               (failed #f)
               (saved (filter (lambda (s) (not (eq? (car s) 'include-settings))) (ly:all-options))))
          (chdir (dirname file))
          (ly:set-option 'backend 'svg)
          (ly:set-option 'point-and-click #t)
          (set! pondside-job-settings settings)
          (catch 'ly-file-failed
                 (lambda () (ly:parse-file file))
                 (lambda (key . args) (set! failed #t)))
          (ly:check-expected-warnings)
          (session-terminate)
          (for-each (lambda (s) (ly:set-option (car s) (cdr s))) saved)
          (ly:reset-all-fonts)
          (flush-all-ports)
          (display (if failed "\\nPONDSIDE-DONE failed\\n" "\\nPONDSIDE-DONE ok\\n") (current-error-port))
          (force-output (current-error-port)))
        (loop)))

    """

    public struct Died: Error, CustomStringConvertible {
        public var log: String
        public var description: String { "the LilyPond daemon stopped:\n\(log)" }
    }

    /// Compiles `source` for the canvas into `outputDirectory`, starting
    /// (or restarting) the process as needed.
    public func engrave(_ source: URL, outputDirectory: URL, extraSettings: String = "") async throws -> EngraveResult {
        if process == nil || jobs >= maxJobs || process?.isRunning == false {
            try await restart()
        }
        guard let input, let pipe else { throw Died(log: "not running") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = outputDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
        let settings = outputDirectory.appendingPathComponent("pondside-session.ily")
        let text = SessionSettings.canvas + SessionSettings.fastSVG + extraSettings
            + "\\paper { output-filename = \(Self.schemeString(base.path)) }\n"
        try Data(text.utf8).write(to: settings)

        let clock = ContinuousClock()
        let start = clock.now
        jobs += 1
        input.write(Data("\(source.path)\t\(settings.path)\n".utf8))
        let outcome = await pipe.next(timeout: timeout)
        let duration = clock.now - start
        guard let outcome, outcome.status != "died" else {
            stop()
            throw Died(log: outcome?.log ?? "no answer within \(timeout)")
        }
        let files = LilyPondEngraver.outputFiles(in: outputDirectory, base: base.lastPathComponent, extension: "svg")
        // Success with no pages means the job's settings were never read, so
        // output went elsewhere. Let the engraver fall back to a cold compile.
        if outcome.status == "ok" && files.isEmpty {
            stop()
            throw Died(log: "no pages in the job's folder\n" + outcome.log)
        }
        return EngraveResult(outputFiles: files, diagnostics: DiagnosticParser.parse(outcome.log), log: outcome.log,
                             exitStatus: outcome.status == "ok" ? 0 : 1, duration: duration)
    }

    /// Stops the process (it is started again on the next compile).
    public func stop() {
        input?.closeFile()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        input = nil
        pipe?.finish()
        pipe = nil
    }

    private func restart() async throws {
        stop()
        if scriptURL == nil {
            let tmp = FileManager.default.temporaryDirectory
            let id = UUID().uuidString
            let url = tmp.appendingPathComponent("pondside-daemon-\(id).scm")
            try Data(Self.script.utf8).write(to: url)
            let dispatcher = tmp.appendingPathComponent("pondside-daemon-\(id).ily")
            try Data(Self.dispatcher.utf8).write(to: dispatcher)
            scriptURL = url
            dispatcherURL = dispatcher
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installation.executable)
        let expr = "(begin (set-current-module (resolve-module '(lily)))"
            + " (define pondside-dispatcher \(Self.schemeString(dispatcherURL!.path)))"
            + " (load \(Self.schemeString(scriptURL!.path))))"
        // The file argument is never read: the loop never returns. The
        // backend is set at start because LilyPond reads it once while
        // initialising: music-strings-to-paths (glyphs as paths, not text)
        // and the default text fonts in paper-defaults-init.ly both depend
        // on it, and setting it per job comes too late for either.
        p.arguments = ["-dbackend=svg", "-e", expr, "pondside-daemon.ly"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let reader = DaemonPipe()
        // stdout must be drained too, or a chatty score blocks the process.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { reader.appendOutput(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; reader.finish() } else { reader.append(d) }
        }
        p.terminationHandler = { _ in reader.finish() }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        pipe = reader
        jobs = 0
        // Wait for the session to be ready, so the first job's time is honest.
        guard let ready = await reader.next(timeout: timeout), ready.status == "ready" else {
            let log = reader.drain()
            stop()
            throw Died(log: log)
        }
    }

    static func schemeString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The daemon's stderr, split into one log per job at each marker line.
final class DaemonPipe: @unchecked Sendable {
    struct Outcome: Sendable {
        var status: String
        var log: String
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var stdout = Data()
    private var ready: [Outcome] = []
    private var waiter: CheckedContinuation<Outcome?, Never>?
    private var finished = false

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var delivered: [Outcome] = []
        let marker = Data(("\n" + LilyPondDaemon.marker).utf8)
        while let r = buffer.range(of: marker) {
            guard let end = buffer[r.upperBound...].firstIndex(of: UInt8(ascii: "\n")) else { break }
            let status = String(decoding: buffer[r.upperBound..<end], as: UTF8.self)
            let log = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                + String(decoding: stdout, as: UTF8.self)
            stdout = Data()
            buffer = Data(buffer[(end + 1)...])
            delivered.append(Outcome(status: status, log: log))
        }
        ready += delivered
        let resume = deliverLocked()
        lock.unlock()
        resume?()
    }

    func appendOutput(_ data: Data) {
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let resume = deliverLocked()
        lock.unlock()
        resume?()
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Hands the next outcome to a waiter, if both exist.
    private func deliverLocked() -> (() -> Void)? {
        guard let w = waiter else { return nil }
        if !ready.isEmpty {
            let o = ready.removeFirst()
            waiter = nil
            return { w.resume(returning: o) }
        }
        if finished {
            waiter = nil
            let log = String(decoding: buffer, as: UTF8.self)
            return { w.resume(returning: Outcome(status: "died", log: log)) }
        }
        return nil
    }

    /// The next job's outcome; nil after `timeout`.
    func next(timeout: Duration) async -> Outcome? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.cancelWaiter()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome?, Never>) in
            lock.lock()
            waiter = c
            let resume = deliverLocked()
            lock.unlock()
            resume?()
        }
    }

    private func cancelWaiter() {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }
}
