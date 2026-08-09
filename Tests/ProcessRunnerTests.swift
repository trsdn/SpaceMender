import Foundation
import Testing
@testable import SpaceMender

struct ProcessRunnerTests {
    private let shell = URL(filePath: "/bin/sh")

    @Test
    func drainsLargeStandardOutputAndErrorWithoutDeadlocking() async throws {
        let result = try await ProcessRunner().run(
            executable: shell,
            arguments: [
                "-c",
                "(yes E | head -c 200000 >&2) & yes O | head -c 200000; wait"
            ],
            timeout: .seconds(5),
            outputLimit: 300_000
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.data.count == 200_000)
        #expect(result.standardError.data.count == 200_000)
        #expect(!result.standardOutput.wasTruncated)
        #expect(!result.standardError.wasTruncated)
    }

    @Test
    func capturesStandardErrorSeparately() async throws {
        let result = try await ProcessRunner().run(
            executable: shell,
            arguments: ["-c", "printf output; printf warning >&2"]
        )

        #expect(result.standardOutput.text == "output")
        #expect(result.standardError.text == "warning")
    }

    @Test
    func boundsCapturedOutputWhileContinuingToDrain() async throws {
        let result = try await ProcessRunner().run(
            executable: shell,
            arguments: ["-c", "yes X | head -c 200000"],
            timeout: .seconds(5),
            outputLimit: 4_096
        )

        #expect(result.standardOutput.data.count == 4_096)
        #expect(result.standardOutput.wasTruncated)
    }

    @Test
    func timeoutTerminatesProcessAndReturnsStructuredError() async {
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await ProcessRunner().run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .milliseconds(100)
            )
            Issue.record("Expected the process to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Expected a timeout error, got \(error)")
                return
            }
            #expect(result.terminationStatus != 0)
            #expect(started.duration(to: clock.now) < .seconds(3))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test
    func cancellationTerminatesProcessAndReturnsStructuredError() async {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await ProcessRunner().run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["10"]
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the process to be cancelled")
        } catch let error as ProcessRunnerError {
            guard case .cancelled(let result) = error else {
                Issue.record("Expected a cancellation error, got \(error)")
                return
            }
            #expect(result.terminationStatus != 0)
            #expect(started.duration(to: clock.now) < .seconds(3))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test
    func cancellationDoesNotWaitForDescendantHeldPipes() async {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await ProcessRunner().run(
                executable: shell,
                arguments: [
                    "-c",
                    "(trap '' TERM; sleep 10) & wait"
                ]
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the process to be cancelled")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Expected a cancellation error, got \(error)")
                return
            }
            #expect(started.duration(to: clock.now) < .seconds(3))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test
    func timeoutDoesNotWaitForDescendantHeldPipes() async {
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await ProcessRunner().run(
                executable: shell,
                arguments: [
                    "-c",
                    "(trap '' TERM; sleep 10) & wait"
                ],
                timeout: .milliseconds(100)
            )
            Issue.record("Expected the process to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Expected a timeout error, got \(error)")
                return
            }
            #expect(started.duration(to: clock.now) < .seconds(3))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test
    func successfulParentDoesNotWaitForDescendantHeldPipes() async throws {
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await ProcessRunner().run(
            executable: shell,
            arguments: [
                "-c",
                "(trap '' TERM; sleep 10) & exit 0"
            ]
        )

        #expect(result.terminationStatus == 0)
        #expect(started.duration(to: clock.now) < .seconds(3))
    }

    @Test
    func cancellationAfterParentExitRemainsBounded() async {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await ProcessRunner().run(
                executable: shell,
                arguments: [
                    "-c",
                    "(trap '' TERM; sleep 10) & exit 0"
                ]
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the output drain to observe cancellation")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Expected a cancellation error, got \(error)")
                return
            }
            #expect(started.duration(to: clock.now) < .seconds(3))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test
    func nonzeroExitIncludesStatusAndCapturedError() async {
        do {
            _ = try await ProcessRunner().run(
                executable: shell,
                arguments: ["-c", "printf failure >&2; exit 23"]
            )
            Issue.record("Expected a nonzero exit")
        } catch let error as ProcessRunnerError {
            guard case .nonZeroExit(let result) = error else {
                Issue.record("Expected a nonzero-exit error, got \(error)")
                return
            }
            #expect(result.terminationStatus == 23)
            #expect(result.standardError.text == "failure")
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }
}
