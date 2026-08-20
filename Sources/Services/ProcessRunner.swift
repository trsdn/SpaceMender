import Darwin
import Foundation

struct ProcessRunner: Sendable {
    static let defaultOutputLimit = 1_048_576
    private static let outputDrainGrace: Duration = .seconds(1)

    func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration? = nil,
        outputLimit: Int = defaultOutputLimit
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.executableNotAvailable(executable)
        }
        guard outputLimit >= 0 else {
            throw ProcessRunnerError.invalidOutputLimit
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        // Assigning `nil` to `Process.environment` launches the child with a
        // completely empty environment rather than inheriting the parent's, so
        // tools that require `HOME` (such as `brew`) fail. Inherit explicitly.
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let execution = ProcessExecution(process: process)
        let outputPipes = ProcessOutputPipes(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        let stdoutTask = outputPipes.drainStandardOutput(limit: outputLimit)
        let stderrTask = outputPipes.drainStandardError(limit: outputLimit)

        do {
            try execution.start()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw ProcessRunnerError.launchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }

        let completion: ProcessCompletion
        do {
            completion = try await withTaskCancellationHandler {
                try await waitForCompletion(execution, timeout: timeout)
            } onCancel: {
                execution.terminate()
            }
        } catch is CancellationError {
            execution.terminate()
            let terminated = await execution.waitForExit()
            outputPipes.stopDraining()
            let result = await makeResult(
                completion: terminated,
                stdoutTask: stdoutTask,
                stderrTask: stderrTask,
                outputPipes: outputPipes
            )
            throw ProcessRunnerError.cancelled(result)
        } catch is ProcessTimeoutError {
            execution.terminate()
            let terminated = await execution.waitForExit()
            outputPipes.stopDraining()
            let result = await makeResult(
                completion: terminated,
                stdoutTask: stdoutTask,
                stderrTask: stderrTask,
                outputPipes: outputPipes
            )
            throw ProcessRunnerError.timedOut(result)
        }

        if Task.isCancelled {
            outputPipes.stopDraining()
            let result = await makeResult(
                completion: completion,
                stdoutTask: stdoutTask,
                stderrTask: stderrTask,
                outputPipes: outputPipes
            )
            throw ProcessRunnerError.cancelled(result)
        }

        let result = await makeResult(
            completion: completion,
            stdoutTask: stdoutTask,
            stderrTask: stderrTask,
            outputPipes: outputPipes
        )
        if Task.isCancelled {
            throw ProcessRunnerError.cancelled(result)
        }
        guard result.terminationStatus == 0 else {
            throw ProcessRunnerError.nonZeroExit(result)
        }
        return result
    }

    private func waitForCompletion(
        _ execution: ProcessExecution,
        timeout: Duration?
    ) async throws -> ProcessCompletion {
        guard let timeout else {
            return await execution.waitForExit()
        }

        let completion: ProcessCompletion = try await withCheckedThrowingContinuation { continuation in
            let race = ProcessCompletionRace(continuation: continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    race.resolve(.failure(ProcessTimeoutError()))
                } catch {
                    // The process completed before the timeout.
                }
            }
            Task {
                let completion = await execution.waitForExit()
                timeoutTask.cancel()
                race.resolve(.success(completion))
            }
        }
        try Task.checkCancellation()
        return completion
    }

    private func makeResult(
        completion: ProcessCompletion,
        stdoutTask: Task<CapturedProcessOutput, Never>,
        stderrTask: Task<CapturedProcessOutput, Never>,
        outputPipes: ProcessOutputPipes
    ) async -> ProcessResult {
        // A descendant may outlive the direct process while retaining inherited
        // pipe descriptors. Bound the drain even when the direct process exited
        // successfully and no timeout/cancellation handler remains active.
        let drainDeadline = Task.detached {
            try? await Task.sleep(for: Self.outputDrainGrace)
            outputPipes.stopDraining()
        }
        async let stdout = stdoutTask.value
        async let stderr = stderrTask.value
        let result = await ProcessResult(
            terminationStatus: completion.status,
            terminationReason: completion.reason,
            standardOutput: stdout,
            standardError: stderr
        )
        drainDeadline.cancel()
        return result
    }

    /// Owns the read ends of a child process's output pipes and drains them.
    ///
    /// Two properties matter here, and both were learned from a CI runner
    /// rather than from a local run:
    ///
    /// 1. Reading goes through `Darwin.read` rather than `FileHandle`.
    ///    `FileHandle` raises an *Objective-C* exception when its descriptor
    ///    becomes invalid during a read, and an uncaught Objective-C exception
    ///    terminates the process. Swift cannot catch it.
    /// 2. Stopping a drain signals a self-pipe instead of closing the
    ///    descriptor a reader is blocked on. Closing a descriptor out from
    ///    under a blocked reader is what made the descriptor invalid in the
    ///    first place.
    ///
    /// The blocking reads run on a dedicated concurrent dispatch queue rather
    /// than on `Task.detached`. The Swift concurrency pool has roughly one
    /// thread per core, so two blocking drains plus the awaiting task starve a
    /// small runner.
    private final class ProcessOutputPipes: @unchecked Sendable {
        private static let queue = DispatchQueue(
            label: "app.spacemender.process-output-drain",
            attributes: .concurrent
        )

        // Retained so the descriptors below stay open for the reader's lifetime.
        private let stdoutHandle: FileHandle
        private let stderrHandle: FileHandle
        private let lock = NSLock()
        private var stopReader: Int32 = -1
        private var stopWriter: Int32 = -1
        private var didStop = false

        init(stdout: FileHandle, stderr: FileHandle) {
            self.stdoutHandle = stdout
            self.stderrHandle = stderr

            var descriptors: [Int32] = [-1, -1]
            if pipe(&descriptors) == 0 {
                stopReader = descriptors[0]
                stopWriter = descriptors[1]
            }
        }

        deinit {
            if stopReader >= 0 {
                Darwin.close(stopReader)
            }
            if stopWriter >= 0 {
                Darwin.close(stopWriter)
            }
        }

        func drainStandardOutput(limit: Int) -> Task<CapturedProcessOutput, Never> {
            drain(stdoutHandle.fileDescriptor, limit: limit)
        }

        func drainStandardError(limit: Int) -> Task<CapturedProcessOutput, Never> {
            drain(stderrHandle.fileDescriptor, limit: limit)
        }

        /// Asks in-flight drains to return what they have already captured.
        ///
        /// A descendant process can inherit the write end and hold it open long
        /// after the direct child exits, so a reader must be able to give up
        /// without waiting for end-of-file.
        func stopDraining() {
            let writer: Int32 = lock.withLock {
                guard !didStop else {
                    return -1
                }
                didStop = true
                return stopWriter
            }
            guard writer >= 0 else {
                return
            }
            var token: UInt8 = 1
            // The pipe is level-triggered, so a single byte stops every reader
            // and also stops one that has not started yet.
            _ = Darwin.write(writer, &token, 1)
        }

        private func drain(_ descriptor: Int32, limit: Int) -> Task<CapturedProcessOutput, Never> {
            let stop = lock.withLock { stopReader }
            return Task.detached {
                await withCheckedContinuation { continuation in
                    Self.queue.async {
                        continuation.resume(
                            returning: Self.read(descriptor, stop: stop, limit: limit)
                        )
                    }
                }
            }
        }

        private static func read(
            _ descriptor: Int32,
            stop: Int32,
            limit: Int
        ) -> CapturedProcessOutput {
            var captured = Data()
            var truncated = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

            loop: while true {
                if stop >= 0 {
                    var descriptors = [
                        pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: stop, events: Int16(POLLIN), revents: 0)
                    ]
                    let ready = poll(&descriptors, 2, -1)
                    if ready < 0 {
                        if errno == EINTR {
                            continue loop
                        }
                        break loop
                    }
                    if descriptors[1].revents & Int16(POLLIN) != 0 {
                        break loop
                    }
                    let readable = Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)
                    if descriptors[0].revents & readable == 0 {
                        continue loop
                    }
                }

                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0 {
                    if errno == EINTR {
                        continue loop
                    }
                    break loop
                }
                if count == 0 {
                    break loop
                }

                let remaining = max(0, limit - captured.count)
                if remaining > 0 {
                    captured.append(contentsOf: buffer[0..<min(remaining, count)])
                }
                if count > remaining {
                    truncated = true
                }
            }

            return CapturedProcessOutput(data: captured, wasTruncated: truncated)
        }
    }
}

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let terminationReason: Process.TerminationReason
    let standardOutput: CapturedProcessOutput
    let standardError: CapturedProcessOutput
}

struct CapturedProcessOutput: Sendable {
    let data: Data
    let wasTruncated: Bool

    var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

enum ProcessRunnerError: LocalizedError {
    case executableNotAvailable(URL)
    case invalidOutputLimit
    case launchFailed(executable: URL, message: String)
    case nonZeroExit(ProcessResult)
    case timedOut(ProcessResult)
    case cancelled(ProcessResult)

    var result: ProcessResult? {
        switch self {
        case .nonZeroExit(let result), .timedOut(let result), .cancelled(let result):
            result
        case .executableNotAvailable, .invalidOutputLimit, .launchFailed:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .executableNotAvailable(let executable):
            return "\(executable.lastPathComponent) is not available on this Mac."
        case .invalidOutputLimit:
            return "The process output limit cannot be negative."
        case .launchFailed(let executable, _):
            return "Could not launch \(executable.lastPathComponent)."
        case .nonZeroExit:
            return "The cleanup tool could not complete the operation."
        case .timedOut:
            return "The process timed out."
        case .cancelled:
            return "The process was cancelled."
        }
    }
}

private struct ProcessTimeoutError: Error {}

private struct ProcessCompletion: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
}

private final class ProcessExecution: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var completion: ProcessCompletion?
    private var waiters: [CheckedContinuation<ProcessCompletion, Never>] = []

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(
                ProcessCompletion(
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            )
        }
    }

    func start() throws {
        try process.run()
    }

    func waitForExit() async -> ProcessCompletion {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let completion {
                    continuation.resume(returning: completion)
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    func terminate() {
        let shouldTerminate = lock.withLock {
            completion == nil
        }
        if shouldTerminate, process.isRunning {
            process.terminate()
            let processIdentifier = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self else {
                    return
                }
                let shouldForceTerminate = self.lock.withLock {
                    self.completion == nil
                }
                if shouldForceTerminate, self.process.isRunning {
                    Darwin.kill(processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func didTerminate(_ completion: ProcessCompletion) {
        let waiters = lock.withLock {
            guard self.completion == nil else {
                return [CheckedContinuation<ProcessCompletion, Never>]()
            }
            self.completion = completion
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: completion)
        }
    }
}

private final class ProcessCompletionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessCompletion, any Error>?

    init(continuation: CheckedContinuation<ProcessCompletion, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<ProcessCompletion, any Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
