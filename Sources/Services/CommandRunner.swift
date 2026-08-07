import Foundation

struct CommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

struct CommandRunner: CommandRunning {
    private let processRunner = ProcessRunner()

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let result = try await processRunner.run(
            executable: executable,
            arguments: arguments
        )
        return CommandResult(
            standardOutput: result.standardOutput.data,
            standardError: result.standardError.data,
            terminationStatus: result.terminationStatus
        )
    }
}
