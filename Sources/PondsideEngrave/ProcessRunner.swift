import Foundation

/// The captured result of running a subprocess.
public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// A reference cell for handing values across the threads a subprocess uses.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

final class ProcessSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let cancel = cancelled
        lock.unlock()
        if cancel, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

public enum ProcessRunner {
    public struct LaunchError: Error, CustomStringConvertible {
        public var executable: String
        public var underlying: String
        public var description: String { "could not launch \(executable): \(underlying)" }
    }

    /// Runs a process to completion, draining both pipes concurrently so a
    /// chatty child can never deadlock on a full pipe buffer.
    public static func run(_ executable: String, _ arguments: [String],
                           currentDirectory: String? = nil,
                           environment: [String: String]? = nil) async throws -> ProcessOutput {
        let slot = ProcessSlot()
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(executable, arguments,
                                                                       currentDirectory: currentDirectory,
                                                                       environment: environment, slot: slot))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            slot.cancel()
        }
        if Task.isCancelled { throw CancellationError() }
        return output
    }

    public static func runBlocking(_ executable: String, _ arguments: [String],
                                   currentDirectory: String? = nil,
                                   environment: [String: String]? = nil) throws -> ProcessOutput {
        try runBlocking(executable, arguments, currentDirectory: currentDirectory, environment: environment, slot: nil)
    }

    private static func runBlocking(_ executable: String, _ arguments: [String],
                                    currentDirectory: String? = nil,
                                    environment: [String: String]? = nil,
                                    slot: ProcessSlot?) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            slot?.install(process)
        } catch {
            throw LaunchError(executable: executable, underlying: String(describing: error))
        }

        let outHandle = LockedBox(outPipe.fileHandleForReading)
        let outData = LockedBox(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData.value = outHandle.value.readDataToEndOfFile()
            group.leave()
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, stdout: outData.value, stderr: errData)
    }
}
