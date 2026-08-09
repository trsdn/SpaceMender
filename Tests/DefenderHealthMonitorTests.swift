import Foundation
import Testing
@testable import SpaceMender

struct DefenderHealthMonitorTests {
    @Test
    func healthyFieldReportsHealthy() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/bin/true"),
            fileManager: FakeExecutableFileManager(executablePaths: ["/usr/bin/true"]),
            commandRunner: FixedMDATPCommandRunner(standardOutput: "true\n")
        )

        let status = await monitor.currentStatus()

        #expect(status == .healthy)
    }

    @Test
    func falseFieldReportsAttentionNeededWithMessageDecoupledFromCleanup() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/bin/true"),
            fileManager: FakeExecutableFileManager(executablePaths: ["/usr/bin/true"]),
            commandRunner: FixedMDATPCommandRunner(standardOutput: "false\n")
        )

        let status = await monitor.currentStatus()

        guard case .attentionNeeded(let message) = status else {
            Issue.record("Expected attentionNeeded, got \(status)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("unrelated"))
        #expect(!message.localizedCaseInsensitiveContains("cleanup fixed"))
    }

    @Test
    func missingToolReportsUnknownRatherThanUnhealthy() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/local/bin/mdatp-does-not-exist"),
            fileManager: FakeExecutableFileManager(executablePaths: []),
            commandRunner: FixedMDATPCommandRunner(standardOutput: "true\n")
        )

        let status = await monitor.currentStatus()

        guard case .unknown = status else {
            Issue.record("Expected unknown, got \(status)")
            return
        }
    }

    @Test
    func unparseableOutputReportsUnknown() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/bin/true"),
            fileManager: FakeExecutableFileManager(executablePaths: ["/usr/bin/true"]),
            commandRunner: FixedMDATPCommandRunner(standardOutput: "maybe\n")
        )

        let status = await monitor.currentStatus()

        guard case .unknown = status else {
            Issue.record("Expected unknown, got \(status)")
            return
        }
    }

    @Test
    func nonZeroExitReportsUnknown() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/bin/true"),
            fileManager: FakeExecutableFileManager(executablePaths: ["/usr/bin/true"]),
            commandRunner: FixedMDATPCommandRunner(standardOutput: "true\n", terminationStatus: 1)
        )

        let status = await monitor.currentStatus()

        guard case .unknown = status else {
            Issue.record("Expected unknown, got \(status)")
            return
        }
    }

    @Test
    func commandFailureReportsUnknownInsteadOfThrowing() async throws {
        let monitor = MDATPHealthMonitor(
            executable: URL(filePath: "/usr/bin/true"),
            fileManager: FakeExecutableFileManager(executablePaths: ["/usr/bin/true"]),
            commandRunner: ThrowingMDATPCommandRunner()
        )

        let status = await monitor.currentStatus()

        guard case .unknown = status else {
            Issue.record("Expected unknown, got \(status)")
            return
        }
    }

    /// Regression test: `mdatp` is a client to Microsoft Defender's
    /// background daemon. If that daemon is slow or unresponsive, the
    /// health check must still return within a bounded time rather than
    /// hanging the app indefinitely.
    @Test
    func realProcessRunnerEnforcesATimeoutAgainstAHungCommand() async throws {
        // `MDATPProcessRunner` always passes `health --field healthy` as
        // arguments, so the fixture "mdatp" ignores its arguments entirely
        // and just sleeps, simulating an unresponsive Defender daemon.
        let fileManager = FileManager.default
        let scriptDirectory = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scriptDirectory) }
        let hungMDATP = scriptDirectory.appending(path: "hung-mdatp")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: hungMDATP)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hungMDATP.path)

        let clock = ContinuousClock()
        let started = clock.now
        let runner = MDATPProcessRunner(timeout: .milliseconds(200))

        do {
            _ = try await runner.runHealthCheck(executable: hungMDATP)
            Issue.record("Expected the health check to time out")
        } catch {
            // Expected: any thrown error is fine here, the timing bound is
            // what matters.
        }

        #expect(started.duration(to: clock.now) < .seconds(3))
    }
}

private final class FakeExecutableFileManager: FileManager, @unchecked Sendable {
    private let executablePaths: Set<String>

    init(executablePaths: [String]) {
        self.executablePaths = Set(executablePaths)
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private struct FixedMDATPCommandRunner: MDATPCommandRunning {
    let standardOutput: String
    var terminationStatus: Int32 = 0

    func runHealthCheck(executable: URL) async throws -> CommandResult {
        CommandResult(
            standardOutput: Data(standardOutput.utf8),
            standardError: Data(),
            terminationStatus: terminationStatus
        )
    }
}

private struct ThrowingMDATPCommandRunner: MDATPCommandRunning {
    struct Failure: Error {}

    func runHealthCheck(executable: URL) async throws -> CommandResult {
        throw Failure()
    }
}
