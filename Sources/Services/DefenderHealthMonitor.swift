import Foundation

/// Microsoft Defender's own health state (its real-time-protection "event
/// provider"), reported completely independently of SpaceMender's
/// diagnostic-archive cleanup. A successful archive cleanup never implies
/// Defender's underlying health issue is fixed, and a Defender health
/// problem never blocks or alters archive cleanup: the two are unrelated
/// concerns that must never be conflated in the UI.
enum DefenderHealthStatus: Sendable, Equatable {
    /// `mdatp health --field healthy` reported `true`.
    case healthy
    /// `mdatp health --field healthy` reported `false`. The associated
    /// message explains this is unrelated to diagnostic cleanup.
    case attentionNeeded(String)
    /// The health tool is missing, failed to run, timed out, or returned
    /// output that could not be interpreted confidently. SpaceMender never
    /// guesses a health state it cannot verify.
    case unknown(String)
}

protocol DefenderHealthMonitoring: Sendable {
    func currentStatus() async -> DefenderHealthStatus
}

/// Runs the `mdatp` health check under a hard timeout. `mdatp` is a client
/// to Microsoft Defender's background daemon: if that daemon is slow,
/// unresponsive, or not running, the command can block far longer than a
/// purely informational health check should ever be allowed to. This is
/// intentionally independent of the shared `CommandRunning` abstraction
/// (which has no timeout of its own) so a stuck health check can never
/// freeze the app.
protocol MDATPCommandRunning: Sendable {
    func runHealthCheck(executable: URL) async throws -> CommandResult
}

struct MDATPProcessRunner: MDATPCommandRunning {
    private let processRunner = ProcessRunner()
    private let timeout: Duration

    init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    func runHealthCheck(executable: URL) async throws -> CommandResult {
        let result = try await processRunner.run(
            executable: executable,
            arguments: ["health", "--field", "healthy"],
            timeout: timeout
        )
        return CommandResult(
            standardOutput: result.standardOutput.data,
            standardError: result.standardError.data,
            terminationStatus: result.terminationStatus
        )
    }
}

/// Reads Microsoft Defender for Endpoint's own health state via its
/// unprivileged `mdatp` command-line tool. This never touches the
/// privileged Defender helper: `mdatp health` runs as the current user, is
/// unrelated to diagnostic-archive deletion, and cannot delete anything.
final class MDATPHealthMonitor: DefenderHealthMonitoring, @unchecked Sendable {
    private let executable: URL
    private let fileManager: FileManager
    private let commandRunner: any MDATPCommandRunning

    init(
        executable: URL = URL(filePath: "/usr/local/bin/mdatp"),
        fileManager: FileManager = .default,
        commandRunner: any MDATPCommandRunning = MDATPProcessRunner()
    ) {
        self.executable = executable
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func currentStatus() async -> DefenderHealthStatus {
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return .unknown("Microsoft Defender’s mdatp command-line tool was not found on this Mac.")
        }
        guard let result = try? await commandRunner.runHealthCheck(executable: executable),
              result.terminationStatus == 0 else {
            return .unknown("Microsoft Defender’s health could not be checked.")
        }
        let text = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch text {
        case "true":
            return .healthy
        case "false":
            return .attentionNeeded(
                "Microsoft Defender reports a health issue with its real-time protection. This "
                    + "is unrelated to diagnostic archive cleanup and must be resolved in "
                    + "Microsoft Defender, not SpaceMender."
            )
        default:
            return .unknown("Microsoft Defender returned an unrecognized health value.")
        }
    }
}
