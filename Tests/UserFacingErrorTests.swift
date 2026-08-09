import Foundation
import Testing
@testable import SpaceMender

struct UserFacingErrorTests {
    @Test
    func commandFailureKeepsRawOutputOutOfPrimaryMessage() {
        let rawOutput = "fatal: internal tool detail --token redacted"
        let error = CleanupProviderError.commandFailed(rawOutput)

        let presentation = UserFacingError.scan(error, categoryName: "Homebrew cleanup")

        #expect(presentation.message == "Homebrew cleanup couldn’t be scanned.")
        #expect(presentation.recoverySuggestion?.contains("rescan") == true)
        #expect(!presentation.alertMessage.contains(rawOutput))
        #expect(presentation.technicalDetails == rawOutput)
    }

    @Test
    func processFailureIncludesStatusAndBoundedDiagnosticsOnlyAsDetails() {
        let result = ProcessResult(
            terminationStatus: 23,
            terminationReason: .exit,
            standardOutput: CapturedProcessOutput(data: Data(), wasTruncated: false),
            standardError: CapturedProcessOutput(
                data: Data("vendor stderr".utf8),
                wasTruncated: false
            )
        )

        let presentation = UserFacingError.cleanup(
            ProcessRunnerError.nonZeroExit(result),
            categoryName: "Unavailable simulators"
        )

        #expect(!presentation.alertMessage.contains("vendor stderr"))
        #expect(presentation.technicalDetails?.contains("Exit status: 23") == true)
        #expect(presentation.technicalDetails?.contains("vendor stderr") == true)
    }

    @Test
    func unknownScanErrorProvidesRecoveryWithoutExposingTechnicalText() {
        let error = NSError(
            domain: "Fixture",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "low-level path detail"]
        )

        let presentation = UserFacingError.scan(error, categoryName: "Old user logs")

        #expect(presentation.message == "The category couldn’t be scanned.")
        #expect(presentation.recoverySuggestion?.contains("scan again") == true)
        #expect(!presentation.alertMessage.contains("low-level path detail"))
        #expect(presentation.technicalDetails == "low-level path detail")
    }
}
