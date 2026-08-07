import Darwin
import Foundation

struct ProcessRunner: Sendable {
    static let defaultOutputLimit = 1_048_576

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
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let execution = ProcessExecution(process: process)
        let stdoutTask = Task.detached {
            Self.drain(stdoutPipe.fileHandleForReading, limit: outputLimit)
        }
        let stderrTask = Task.detached {
            Self.drain(stderrPipe.fileHandleForReading, limit: outputLimit)
        }

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
            let result = await makeResult(
                completion: terminated,
                stdoutTask: stdoutTask,
                stderrTask: stderrTask
            )
            throw ProcessRunnerError.cancelled(result)
        } catch is ProcessTimeoutError {
            execution.terminate()
            let terminated = await execution.waitForExit()
            let result = await makeResult(
                completion: terminated,
                stdoutTask: stdoutTask,
                stderrTask: stderrTask
            )
            throw ProcessRunnerError.timedOut(result)
        }

        let result = await makeResult(
            completion: completion,
            stdoutTask: stdoutTask,
            stderrTask: stderrTask
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
        stderrTask: Task<CapturedProcessOutput, Never>
    ) async -> ProcessResult {
        async let stdout = stdoutTask.value
        async let stderr = stderrTask.value
        return await ProcessResult(
            terminationStatus: completion.status,
            terminationReason: completion.reason,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    private static func drain(
        _ handle: FileHandle,
        limit: Int
    ) -> CapturedProcessOutput {
        var captured = Data()
        var truncated = false

        while true {
            let chunk = handle.readData(ofLength: 64 * 1_024)
            guard !chunk.isEmpty else {
                break
            }

            let remaining = max(0, limit - captured.count)
            if remaining > 0 {
                captured.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        try? handle.close()
        return CapturedProcessOutput(data: captured, wasTruncated: truncated)
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
        case .launchFailed(let executable, let message):
            return "Could not launch \(executable.lastPathComponent): \(message)"
        case .nonZeroExit(let result):
            let details = result.standardError.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return details.isEmpty
                ? "The process exited with status \(result.terminationStatus)."
                : details
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
