import Foundation

struct CommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> CommandResult
}

struct CommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandRunnerError.toolNotAvailable(executable.lastPathComponent)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SpaceMender-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appending(path: "stdout")
        let errorURL = temporaryDirectory.appending(path: "stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let standardOutput = try FileHandle(forWritingTo: outputURL)
        let standardError = try FileHandle(forWritingTo: errorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()
        try standardOutput.synchronize()
        try standardError.synchronize()

        return CommandResult(
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try Data(contentsOf: errorURL),
            terminationStatus: process.terminationStatus
        )
    }
}

enum CommandRunnerError: LocalizedError {
    case toolNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .toolNotAvailable(let tool):
            "\(tool) is not available on this Mac."
        }
    }
}
