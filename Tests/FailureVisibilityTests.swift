import Foundation
import Testing
@testable import SpaceMender

/// Guards issues #11 and #8: when something goes wrong, the app must say what happened rather
/// than describe itself in a circle, blame a cause it never established, or answer with silence.
@MainActor
struct FailureVisibilityTests {
    // MARK: - #11 · The warning must carry real information

    @Test
    func toolFailureSuggestionDoesNotReferToItself() {
        let presented = UserFacingError.scan(
            CleanupProviderError.commandFailed("Exit status: 1\nError: $HOME must be set to run brew."),
            categoryName: "Homebrew cleanup"
        )

        let suggestion = presented.recoverySuggestion ?? ""

        #expect(
            !suggestion.localizedCaseInsensitiveContains("this category’s warning"),
            """
            The suggestion is rendered *inside* the category warning, so telling the user to \
            review that warning points them at this very sentence. Got: \(suggestion)
            """
        )
        #expect(
            !suggestion.localizedCaseInsensitiveContains("quit affected apps"),
            """
            Nothing established that an app was holding a file open — this failure was a tool \
            exiting non-zero. Asserting a cause sends the user to do irrelevant work. \
            Got: \(suggestion)
            """
        )
    }

    @Test
    func toolFailureMakesTheToolsOwnMessageReadable() {
        let toolOutput = "Exit status: 1\nError: $HOME must be set to run brew."
        let presented = UserFacingError.scan(
            CleanupProviderError.commandFailed(toolOutput),
            categoryName: "Homebrew cleanup"
        )

        #expect(
            presented.technicalDetails?.contains("$HOME must be set to run brew") == true,
            "The tool's own message must survive into technicalDetails"
        )
        #expect(
            presented.detailedAlertMessage.contains("$HOME must be set to run brew"),
            """
            An alert can host no disclosure control, so the details have to be in the message \
            itself; otherwise the only explanation is reachable only via the clipboard. \
            Got: \(presented.detailedAlertMessage)
            """
        )
    }

    @Test
    func technicalDetailsAreRenderedOnScreenAndNotOnlyCopied() throws {
        for view in ["OverviewView.swift", "ContentView.swift"] {
            let source = try sourceOfView(named: view)
            let detailBlocks = source.components(separatedBy: "technicalDetails")

            #expect(
                source.contains("DisclosureGroup(\"Details\")"),
                "\(view) must render technical details on screen, not only offer to copy them"
            )
            #expect(
                detailBlocks.count > 1,
                "\(view) should still consume technicalDetails"
            )
        }
    }

    // MARK: - #8 · An empty plan must be answered, not ignored

    @Test
    func emptyPlanIsReportedInsteadOfSilentlyDoingNothing() async throws {
        let rule = CleanupRule.xcodeDerivedData
        let item = makeItem(id: "vanished", rule: rule)
        let providerResult = OverviewProviderResult(
            rule: rule,
            items: [item],
            scannedAt: .now,
            status: .available,
            warnings: [],
            safeItemIDs: [OverviewItemID(providerID: rule.id, itemID: item.id)]
        )
        let viewModel = AppViewModel(
            defenderHealthMonitor: HealthyMonitorStub(),
            overviewScanner: EmptyPlanOverviewScanner(result: providerResult)
        )

        viewModel.scanOverview()
        for _ in 0..<100 where viewModel.overviewItems.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        viewModel.setProviderSelected(true, providerID: rule.id)
        viewModel.requestOverviewCleanup()
        for _ in 0..<100 where viewModel.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            viewModel.errorMessage != nil,
            """
            The user pressed a button; a plan that resolves to nothing must be reported. \
            Returning silently makes the button look dead.
            """
        )
        #expect(
            viewModel.frozenOverviewPlan == nil,
            "No plan should be frozen when there is nothing to clean"
        )
        #expect(
            !viewModel.showingOverviewConfirmation,
            "The confirmation sheet must not open for an empty plan"
        )
    }

    @Test
    func confirmingAnEmptyFrozenPlanClosesTheSheetAndReports() {
        let viewModel = AppViewModel(defenderHealthMonitor: HealthyMonitorStub())
        viewModel.showingOverviewConfirmation = true

        viewModel.performOverviewCleanup()

        #expect(viewModel.errorMessage != nil, "The defensive guard must also report")
        #expect(
            !viewModel.showingOverviewConfirmation,
            "Leaving the sheet open after a no-op strands the user on a dead confirmation"
        )
    }

    // MARK: - Helpers

    private func sourceOfView(named name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appending(path: "Sources", directoryHint: .isDirectory)
            .appending(path: "Views", directoryHint: .isDirectory)
            .appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeItem(id: String, rule: CleanupRule) -> CleanupItem {
        CleanupItem(
            id: id,
            providerID: rule.id,
            stableIdentity: id,
            displayName: id,
            url: nil,
            discoveredAt: Date(timeIntervalSince1970: 2_000_000_000),
            modifiedAt: nil,
            resourceIdentifier: nil,
            allocatedSize: 1,
            cleanupPolicy: rule.cleanupPolicy
        )
    }
}

private struct HealthyMonitorStub: DefenderHealthMonitoring {
    func currentStatus() async -> DefenderHealthStatus { .healthy }
}

/// Scans normally but resolves every selection to an empty plan — the shape of items that
/// disappeared between the scan and the moment the plan was frozen.
private actor EmptyPlanOverviewScanner: OverviewScanning {
    let rules: [CleanupRule]
    private let result: OverviewProviderResult

    init(result: OverviewProviderResult) {
        self.rules = [result.rule]
        self.result = result
    }

    func scanAll(
        retentionDaysByProviderID: [String: Int],
        now: Date,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewScanSnapshot {
        await progress(result)
        return OverviewScanSnapshot(providers: [result], startedAt: now, completedAt: now)
    }

    func makeCleanupPlan(
        selections: Set<OverviewItemID>,
        snapshot: OverviewScanSnapshot
    ) async -> CrossProviderCleanupPlan {
        CrossProviderCleanupPlan(
            providerPlans: [],
            rulesByProviderID: [:],
            createdAt: .now
        )
    }
}
