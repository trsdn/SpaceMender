import Foundation

/// A concise, actionable error for the interface. Diagnostic output is kept
/// separate so command stderr is never presented as the primary message.
struct UserFacingError: Sendable, Equatable {
    let message: String
    let recoverySuggestion: String?
    let technicalDetails: String?

    var alertMessage: String {
        [message, recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// `alertMessage` plus the tool's own output, for surfaces that cannot host a disclosure
    /// control. An alert that only offers "Copy Technical Details" hides the one piece of text
    /// that explains the failure behind a clipboard round-trip most users never make.
    var detailedAlertMessage: String {
        guard let technicalDetails, !technicalDetails.isEmpty else { return alertMessage }
        return [alertMessage, technicalDetails].joined(separator: "\n\n")
    }

    /// Shown when a frozen cleanup plan resolves to nothing, so the request is visibly answered
    /// instead of silently dropped.
    static var emptyPlan: UserFacingError {
        UserFacingError(
            message: String(localized: "There was nothing left to clean."),
            recoverySuggestion: String(
                localized: "The selected items were removed or changed since the last scan. Scan again to see what is there now."
            ),
            technicalDetails: nil
        )
    }

    static func scan(_ error: Error, categoryName: String) -> UserFacingError {
        ErrorPresentation.make(error, operation: .scan, categoryName: categoryName)
    }

    static func cleanup(_ error: Error, categoryName: String) -> UserFacingError {
        ErrorPresentation.make(error, operation: .cleanup, categoryName: categoryName)
    }
}

enum ErrorPresentation {
    enum Operation {
        case scan
        case cleanup
    }

    static func make(
        _ error: Error,
        operation: Operation,
        categoryName: String
    ) -> UserFacingError {
        if error is CancellationError {
            return UserFacingError(
                message: String(localized: "The operation was cancelled."),
                recoverySuggestion: nil,
                technicalDetails: nil
            )
        }

        if let processError = error as? ProcessRunnerError {
            return processPresentation(processError, operation: operation, categoryName: categoryName)
        }

        if case CleanupProviderError.commandFailed(let details) = error {
            return toolFailure(
                operation: operation,
                categoryName: categoryName,
                details: details
            )
        }

        if let validationError = error as? CleanupValidationError {
            return UserFacingError(
                message: validationError.localizedDescription,
                recoverySuggestion: String(localized: "Rescan the category before trying again."),
                technicalDetails: nil
            )
        }

        return UserFacingError(
            message: operation == .scan
                ? String(localized: "The category couldn’t be scanned.")
                : String(localized: "The item couldn’t be cleaned."),
            recoverySuggestion: operation == .scan
                ? String(localized: "Check that the location is available and readable, then scan again.")
                : String(localized: "Check that the item is available and that you have permission, then rescan and try again."),
            technicalDetails: bounded(error.localizedDescription)
        )
    }

    private static func processPresentation(
        _ error: ProcessRunnerError,
        operation: Operation,
        categoryName: String
    ) -> UserFacingError {
        switch error {
        case .executableNotAvailable(let executable):
            return UserFacingError(
                message: String(localized: "A required cleanup tool isn’t available."),
                recoverySuggestion: String(localized: "Install or restore \(executable.lastPathComponent), then scan again."),
                technicalDetails: String(localized: "Expected executable: \(executable.path)")
            )
        case .invalidOutputLimit:
            return UserFacingError(
                message: String(localized: "SpaceMender couldn’t start the cleanup tool."),
                recoverySuggestion: String(localized: "Quit and reopen SpaceMender, then try again."),
                technicalDetails: error.localizedDescription
            )
        case .launchFailed(let executable, let details):
            return UserFacingError(
                message: String(localized: "The cleanup tool couldn’t be opened."),
                recoverySuggestion: String(localized: "Check that \(executable.lastPathComponent) is installed and executable, then try again."),
                technicalDetails: bounded(details)
            )
        case .nonZeroExit(let result):
            return toolFailure(
                operation: operation,
                categoryName: categoryName,
                details: processDetails(result)
            )
        case .timedOut(let result):
            return UserFacingError(
                message: String(localized: "The cleanup tool took too long to respond."),
                recoverySuggestion: String(localized: "Quit apps that use this category, then rescan and try again."),
                technicalDetails: processDetails(result)
            )
        case .cancelled:
            return UserFacingError(
                message: String(localized: "The operation was cancelled."),
                recoverySuggestion: nil,
                technicalDetails: nil
            )
        }
    }

    private static func toolFailure(
        operation: Operation,
        categoryName: String,
        details: String
    ) -> UserFacingError {
        UserFacingError(
            message: operation == .scan
                ? String(localized: "\(categoryName) couldn’t be scanned.")
                : String(localized: "The cleanup tool couldn’t complete \(categoryName)."),
            // Neither circular nor speculative: the previous text told the user to "review this
            // category's warning" while *being* that warning, and asserted a cause ("quit
            // affected apps") the app never established. The tool's own message is now rendered
            // next to this suggestion, so pointing at it is accurate.
            recoverySuggestion: String(localized: "The tool’s own message is in the details below. Resolve it, then rescan."),
            technicalDetails: bounded(details)
        )
    }

    private static func processDetails(_ result: ProcessResult) -> String {
        let stderr = result.standardError.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.standardOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = stderr.isEmpty ? stdout : stderr
        let status = String(localized: "Exit status: \(result.terminationStatus)")
        return bounded(output.isEmpty ? status : "\(status)\n\(output)")
    }

    private static func bounded(_ details: String) -> String {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4_000 else { return trimmed }
        return String(trimmed.prefix(4_000)) + String(localized: "\n… Technical details truncated.")
    }
}
