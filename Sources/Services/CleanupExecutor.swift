import AppKit
import Foundation

@MainActor
struct CleanupExecutor {
    private let fileManager = FileManager.default

    func clean(rule: CleanupRule, items: [CleanupItem]) throws {
        guard !items.isEmpty else {
            return
        }

        switch rule.cleanupAction {
        case .deleteFiles(let requiresAdministrator):
            let urls = try validatedURLs(rule: rule, items: items)
            if requiresAdministrator {
                try deleteWithAdministratorPrivileges(urls)
            } else {
                for url in urls {
                    try fileManager.removeItem(at: url)
                }
            }
        case .deleteUnavailableSimulators:
            try run(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "delete", "unavailable"]
            )
        case .runHomebrewCleanup:
            try run(
                executable: URL(filePath: "/opt/homebrew/bin/brew"),
                arguments: ["cleanup"]
            )
        }
    }

    private func validatedURLs(rule: CleanupRule, items: [CleanupItem]) throws -> [URL] {
        try items.map { item in
            guard let url = item.url, rule.contains(url) else {
                throw CleanupExecutorError.invalidCleanupPath
            }
            return url
        }
    }

    private func deleteWithAdministratorPrivileges(_ urls: [URL]) throws {
        let arguments = urls
            .map(\.path)
            .map(shellQuote)
            .joined(separator: " ")
        let shellCommand = "/bin/rm -rf -- \(arguments)"
        let scriptSource = "do shell script \"\(appleScriptQuote(shellCommand))\" with administrator privileges"

        guard let script = NSAppleScript(source: scriptSource) else {
            throw CleanupExecutorError.couldNotCreateAuthorizationRequest
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? "The cleanup request failed."
            throw CleanupExecutorError.commandFailed(message)
        }
    }

    private func run(executable: URL, arguments: [String]) throws {
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CleanupExecutorError.toolNotAvailable(executable.lastPathComponent)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw CleanupExecutorError.commandFailed(
                message.isEmpty ? "The cleanup tool failed." : message
            )
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum CleanupExecutorError: LocalizedError {
    case invalidCleanupPath
    case couldNotCreateAuthorizationRequest
    case toolNotAvailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCleanupPath:
            "SpaceMender refused a cleanup path outside the selected rule."
        case .couldNotCreateAuthorizationRequest:
            "SpaceMender could not create the administrator authorization request."
        case .toolNotAvailable(let tool):
            "\(tool) is not available on this Mac."
        case .commandFailed(let message):
            message
        }
    }
}
