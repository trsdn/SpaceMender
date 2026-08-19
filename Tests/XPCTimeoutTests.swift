import Foundation
import Testing
@testable import SpaceMender

/// Guards issue #9: an XPC call to the root helper had no deadline. A helper that accepted the
/// connection and then never replied left the continuation suspended forever — cleanup appeared
/// to hang with no way out, since `withCheckedThrowingContinuation` ignores cancellation.
struct XPCTimeoutTests {
    /// Rescue deadline for the *test*, distinct from the production timeout under test.
    ///
    /// It cannot be a `withThrowingTaskGroup` race: a task group only returns once every child
    /// has finished, and a task suspended in `withCheckedThrowingContinuation` ignores
    /// cancellation entirely — the group would wait forever. The only way to unblock the
    /// continuation is to settle the gate, so the watchdog does exactly that, with a sentinel
    /// error distinguishable from the production timeout.
    ///
    /// This is the same constraint that shaped the fix itself, and it is why issue #9's
    /// suggested `withThrowingTaskGroup` approach would have deadlocked instead of timing out.
    private static func armWatchdog<Value: Sendable>(on gate: XPCReplyGate<Value>) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            gate.resume(throwing: WatchdogExpired())
        }
    }

    private struct WatchdogExpired: Error {}

    @Test
    func aCallThatNeverRepliesFailsInsteadOfHangingForever() async throws {
        let gate = XPCReplyGate<Int>()
        let timeout = DefenderPrivilegedHelperClient.armTimeout(on: gate, after: .milliseconds(50))
        let watchdog = Self.armWatchdog(on: gate)
        defer {
            timeout.cancel()
            watchdog.cancel()
        }

        await #expect(throws: DefenderHelperClientError.timedOut) {
            // Nothing ever calls `gate.resume` — exactly the unresponsive-helper case.
            // Without the production timeout, only the watchdog settles this, and the thrown
            // `WatchdogExpired` fails the expectation instead of hanging the suite.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                gate.install(continuation)
            }
        }
    }

    @Test
    func aTimelyReplyWinsAndTheTimeoutIsHarmless() async throws {
        let gate = XPCReplyGate<Int>()
        let timeout = DefenderPrivilegedHelperClient.armTimeout(on: gate, after: .seconds(30))
        defer { timeout.cancel() }

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            gate.install(continuation)
            gate.resume(returning: 42)
        }

        #expect(value == 42, "A normal reply must not be disturbed by an armed timeout")
    }

    /// The timeout races four other resumption paths (reply, interruption, invalidation, proxy
    /// error). Double-resuming a `CheckedContinuation` traps, so this must hold absolutely.
    @Test
    func aLateReplyAfterATimeoutCannotResumeTwice() async throws {
        let gate = XPCReplyGate<Int>()
        let timeout = DefenderPrivilegedHelperClient.armTimeout(on: gate, after: .milliseconds(50))
        let watchdog = Self.armWatchdog(on: gate)
        defer {
            timeout.cancel()
            watchdog.cancel()
        }

        await #expect(throws: DefenderHelperClientError.timedOut) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                gate.install(continuation)
            }
        }

        // The helper finally answers, and the connection tears down. Neither may crash.
        gate.resume(returning: 7)
        gate.resume(throwing: DefenderHelperClientError.connectionInvalidated)
    }

    @Test
    func cancellingTheTimeoutStopsItFromFiring() async throws {
        let gate = XPCReplyGate<Int>()
        DefenderPrivilegedHelperClient.armTimeout(on: gate, after: .milliseconds(20)).cancel()
        try await Task.sleep(for: .milliseconds(120))

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            gate.install(continuation)
            gate.resume(returning: 5)
        }

        #expect(
            value == 5,
            """
            `call` cancels the timeout once it settles. If cancellation did not stop it, every \
            completed call would leave a task sleeping until the deadline.
            """
        )
    }

    /// Wiring check: the mechanism above is only worth anything if `call` actually arms it.
    @Test
    func theProductionCallPathArmsTheTimeout() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/Services/DefenderPrivilegedHelperClient.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("let timeoutTask = Self.armTimeout(on: gate, after: timeout)"),
            "Every XPC call must be under a deadline"
        )
        #expect(
            source.contains("defer { timeoutTask.cancel() }"),
            "A settled call must not leave the timeout task sleeping"
        )
    }
}
