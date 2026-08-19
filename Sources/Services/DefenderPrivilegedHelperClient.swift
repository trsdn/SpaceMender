import Foundation
import ServiceManagement

enum DefenderHelperAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    case requiresApproval
    case outdated
    case unauthenticated
    case unavailable

    var unavailableReason: String? {
        switch self {
        case .ready:
            nil
        case .notInstalled:
            "Cleanup is scan-only until the privileged helper is installed."
        case .requiresApproval:
            "Cleanup is scan-only until the privileged helper is approved in System Settings."
        case .outdated:
            "Cleanup is scan-only until the privileged helper is upgraded."
        case .unauthenticated:
            "Cleanup is scan-only because the privileged helper could not authenticate SpaceMender."
        case .unavailable:
            "Cleanup is scan-only because the privileged helper is unavailable."
        }
    }
}

protocol DefenderPrivilegedHelperServing: Sendable {
    var cachedAvailability: DefenderHelperAvailability { get }
    func refreshAvailability() async -> DefenderHelperAvailability
    func remove(candidates: [DefenderCandidateIdentity]) async throws -> [DefenderHelperItemOutcome]
}

final class DefenderPrivilegedHelperClient: DefenderPrivilegedHelperServing, @unchecked Sendable {
    private let lock = NSLock()
    private var availabilityStorage: DefenderHelperAvailability = .notInstalled
    private let service: SMAppService
    private let timeout: Duration

    init(
        service: SMAppService = .daemon(plistName: DefenderHelperConstants.launchDaemonPlistName),
        timeout: Duration = .seconds(30)
    ) {
        self.service = service
        self.timeout = timeout
        availabilityStorage = Self.mapServiceStatus(service.status)
    }

    var cachedAvailability: DefenderHelperAvailability {
        lock.withLock { availabilityStorage }
    }

    func refreshAvailability() async -> DefenderHelperAvailability {
        let serviceState = Self.mapServiceStatus(service.status)
        guard serviceState == .ready else {
            setAvailability(serviceState)
            return serviceState
        }

        do {
            let response: DefenderHelperStatusResponse = try await call { proxy, reply in
                proxy.status(reply: reply)
            }
            let state: DefenderHelperAvailability
            if response.protocolVersion != DefenderHelperConstants.protocolVersion {
                state = .outdated
            } else if !response.authenticated {
                state = .unauthenticated
            } else {
                state = .ready
            }
            setAvailability(state)
            return state
        } catch {
            setAvailability(.unauthenticated)
            return .unauthenticated
        }
    }

    func remove(
        candidates: [DefenderCandidateIdentity]
    ) async throws -> [DefenderHelperItemOutcome] {
        guard await refreshAvailability() == .ready else {
            throw DefenderHelperClientError.notReady
        }
        let request = DefenderHelperCleanupRequest(
            protocolVersion: DefenderHelperConstants.protocolVersion,
            candidates: candidates
        )
        let requestData = try DefenderHelperCoding.encode(request)
        let response: DefenderHelperCleanupResponse = try await call { proxy, reply in
            proxy.removeDefenderDiagnostics(request: requestData, reply: reply)
        }
        return response.outcomes
    }

    private func call<Response: Decodable & Sendable>(
        _ operation: @escaping (DefenderHelperXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> Response {
        let connection = NSXPCConnection(
            machServiceName: DefenderHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: DefenderHelperXPCProtocol.self)
        let gate = XPCReplyGate<Response>()
        connection.interruptionHandler = {
            gate.resume(throwing: DefenderHelperClientError.connectionInterrupted)
        }
        connection.invalidationHandler = {
            gate.resume(throwing: DefenderHelperClientError.connectionInvalidated)
        }
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resume(throwing: error)
        }) as? DefenderHelperXPCProtocol else {
            throw DefenderHelperClientError.invalidProxy
        }

        // A helper that accepts the connection and then never replies would otherwise leave the
        // continuation suspended forever, with no cancellation path — cleanup would appear to
        // hang. The gate only ever resumes once, so a timeout racing a real reply is safe.
        let timeoutTask = Self.armTimeout(on: gate, after: timeout)
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            operation(proxy) { data in
                do {
                    gate.resume(returning: try DefenderHelperCoding.decode(Response.self, from: data))
                } catch {
                    gate.resume(throwing: error)
                }
            }
        }
    }

    /// Settles `gate` with `.timedOut` unless the call finishes first. The returned task must be
    /// cancelled once the call settles, otherwise it lingers until the deadline elapses.
    ///
    /// Extracted so the timeout can be exercised directly: `call` itself is bound to a real
    /// `NSXPCConnection` to a root daemon, which no test can stand up.
    static func armTimeout<Value: Sendable>(
        on gate: XPCReplyGate<Value>,
        after timeout: Duration
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return // Cancelled because the call already settled.
            }
            gate.resume(throwing: DefenderHelperClientError.timedOut)
        }
    }

    private func setAvailability(_ availability: DefenderHelperAvailability) {
        lock.withLock {
            availabilityStorage = availability
        }
    }

    private static func mapServiceStatus(_ status: SMAppService.Status) -> DefenderHelperAvailability {
        switch status {
        case .enabled:
            .ready
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .notInstalled
        @unknown default:
            .unavailable
        }
    }
}

enum DefenderHelperClientError: Error {
    case notReady
    case invalidProxy
    case connectionInterrupted
    case connectionInvalidated
    case timedOut
}

final class DefenderHelperServiceManager: @unchecked Sendable {
    private let service: SMAppService

    init(service: SMAppService = .daemon(plistName: DefenderHelperConstants.launchDaemonPlistName)) {
        self.service = service
    }

    var status: SMAppService.Status {
        service.status
    }

    func installOrUpgrade() throws {
        try service.register()
    }

    func remove() async throws {
        try await service.unregister()
    }
}

/// Guarantees a single resumption of an XPC continuation no matter how many of the racing paths
/// fire — reply, interruption, invalidation, proxy error, or timeout.
final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private enum Pending: @unchecked Sendable {
        case success(Value)
        case failure(NSError)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Pending?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pending: Pending? = lock.withLock {
            if let pending = self.pending {
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let pending {
            resume(continuation, with: pending)
        }
    }

    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error as NSError))
    }

    private func resume(with pending: Pending) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard self.pending == nil else {
                return nil
            }
            self.pending = pending
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if let continuation {
            resume(continuation, with: pending)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Value, Error>,
        with pending: Pending
    ) {
        switch pending {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
