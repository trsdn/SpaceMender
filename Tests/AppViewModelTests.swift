import Foundation
import Testing
@testable import SpaceMender

@MainActor
struct AppViewModelTests {
    @Test
    func newResultsStartWithNothingSelected() {
        let viewModel = AppViewModel(result: makeResult(), defenderHealthMonitor: ImmediateHealthyMonitor())

        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(viewModel.selectedItems.isEmpty)
        #expect(!viewModel.canClean)
    }

    @Test
    func individualSelectionIncludesOnlyRequestedItems() {
        let result = makeResult()
        let viewModel = AppViewModel(result: result, defenderHealthMonitor: ImmediateHealthyMonitor())

        viewModel.setSelected(true, item: result.items[1])

        #expect(viewModel.selectedItemIDs == [result.items[1].id])
        #expect(viewModel.selectedItems.map(\.id) == [result.items[1].id])
        #expect(viewModel.selectedBytes == result.items[1].allocatedSize)
        #expect(viewModel.canClean)

        viewModel.setSelected(false, item: result.items[1])

        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test
    func selectAllAndClearSelectionTrackCurrentItems() {
        let result = makeResult()
        let viewModel = AppViewModel(result: result, defenderHealthMonitor: ImmediateHealthyMonitor())

        viewModel.selectAll()

        #expect(viewModel.selectedItemIDs == Set(result.items.map(\.id)))
        #expect(viewModel.allItemsSelected)

        viewModel.clearSelection()

        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(!viewModel.allItemsSelected)
    }

    @Test
    func defenderSelectionRemainsScanOnly() {
        let result = CleanupScanResult(
            rule: .defenderDiagnostics,
            items: [
                CleanupItem(
                    id: "defender.zip",
                    providerID: CleanupRule.defenderDiagnostics.id,
                    stableIdentity: "/tmp/defender.zip",
                    displayName: "defender.zip",
                    url: URL(filePath: "/tmp/defender.zip"),
                    discoveredAt: Date(),
                    modifiedAt: Date(),
                    resourceIdentifier: nil,
                    allocatedSize: 100,
                    cleanupPolicy: .unavailable
                )
            ],
            scannedAt: Date()
        )
        let viewModel = AppViewModel(result: result, defenderHealthMonitor: ImmediateHealthyMonitor())

        viewModel.selectAll()

        #expect(viewModel.selectedItems.count == 1)
        #expect(!viewModel.canClean)
        #expect(viewModel.selectedRule.cleanupUnavailableReason != nil)
    }

    @Test
    func cleanupAlwaysStartsRescanAfterPartialFailure() async throws {
        let initial = makeResult()
        let scanner = CountingScanner(result: CleanupScanResult(
            rule: initial.rule,
            items: [],
            scannedAt: Date()
        ))
        let cleaner = PartialFailureCleaner()
        let viewModel = AppViewModel(
            result: initial,
            scanner: scanner,
            cleaner: cleaner,
            defenderHealthMonitor: ImmediateHealthyMonitor()
        )
        viewModel.selectAll()

        viewModel.performCleanup()

        for _ in 0..<100 where await scanner.scanCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await scanner.scanCount == 1)
        #expect(viewModel.lastCleanupReport?.outcomes.map(\.status) == [.cleaned, .failed])
        #expect(viewModel.errorMessage != nil)
    }

    @Test
    func staleCancelledScanCannotReplaceNewerResults() async {
        let scanner = DelayedScanner()
        let viewModel = AppViewModel(scanner: scanner, defenderHealthMonitor: ImmediateHealthyMonitor())

        viewModel.selectedRule = .defenderDiagnostics
        viewModel.scan()
        viewModel.selectedRule = .xcodeDerivedData
        viewModel.scan()

        try? await Task.sleep(for: .milliseconds(500))

        #expect(viewModel.result?.rule.id == CleanupRule.xcodeDerivedData.id)
        #expect(viewModel.items.map(\.id) == [CleanupRule.xcodeDerivedData.id])
        #expect(!viewModel.isScanning)
    }

    @Test
    func eachProviderTracksItsOwnRetentionDefaultingToItsDeclaredDefault() {
        let viewModel = AppViewModel(result: makeResult(), defenderHealthMonitor: ImmediateHealthyMonitor())

        viewModel.selectedRule = .defenderDiagnostics
        #expect(viewModel.retentionDays == CleanupRule.defenderDiagnostics.defaultRetentionDays)

        viewModel.retentionDays = 7
        #expect(viewModel.retentionDays == 7)

        // Switching to a different retention-supporting provider must not
        // inherit Defender's chosen value; it starts at its own default.
        viewModel.selectedRule = .xcodeDerivedData
        #expect(viewModel.retentionDays == CleanupRule.xcodeDerivedData.defaultRetentionDays)

        viewModel.retentionDays = 90
        #expect(viewModel.retentionDays == 90)

        // Returning to Defender recalls the value chosen for Defender
        // earlier, not the DerivedData value or a shared global default.
        viewModel.selectedRule = .defenderDiagnostics
        #expect(viewModel.retentionDays == 7)
        viewModel.selectedRule = .xcodeDerivedData
        #expect(viewModel.retentionDays == 90)
    }

    @Test
    func defenderHealthRefreshesOnDefenderScanAndIsIndependentOfCleanupOutcome() async throws {
        let monitor = RecordingHealthMonitor(status: .attentionNeeded("Fixture issue"))
        let scanner = CountingScanner(result: makeResult())
        let cleaner = PartialFailureCleaner()
        let viewModel = AppViewModel(
            result: makeResult(),
            scanner: scanner,
            cleaner: cleaner,
            defenderHealthMonitor: monitor
        )

        #expect(viewModel.defenderHealth == nil)

        viewModel.selectedRule = .defenderDiagnostics
        viewModel.scan()

        for _ in 0..<100 where viewModel.defenderHealth == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.defenderHealth == .attentionNeeded("Fixture issue"))
        #expect(await monitor.callCount == 1)
        let scanCountBeforeCleanup = await scanner.scanCount

        // A cleanup on an unrelated, currently selected provider must never
        // read or reset the Defender health value.
        viewModel.selectedRule = .xcodeDerivedData
        viewModel.selectAll()
        viewModel.performCleanup()

        for _ in 0..<100 where await scanner.scanCount <= scanCountBeforeCleanup {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.defenderHealth == .attentionNeeded("Fixture issue"))
        #expect(await monitor.callCount == 1, "Cleanup must never trigger its own health refresh")
    }

    @Test
    func overviewCleanupStartsRescanAfterPartialFailure() async throws {
        let rule = makeOverviewRule()
        let items = [
            makeOverviewItem(id: "overview-first", rule: rule, bytes: 10),
            makeOverviewItem(id: "overview-second", rule: rule, bytes: 20)
        ]
        let providerResult = OverviewProviderResult(
            rule: rule,
            items: items,
            scannedAt: Date(timeIntervalSince1970: 2_000_000_000),
            status: .available,
            warnings: [],
            safeItemIDs: Set(items.map {
                OverviewItemID(providerID: rule.id, itemID: $0.id)
            })
        )
        let overviewScanner = CountingOverviewScanner(result: providerResult)
        let historyStore = RecordingOverviewHistoryStore()
        let viewModel = AppViewModel(
            defenderHealthMonitor: ImmediateHealthyMonitor(),
            overviewScanner: overviewScanner,
            overviewCleaner: PartialFailureOverviewCleaner(),
            historyStore: historyStore
        )

        viewModel.scanOverview()
        for _ in 0..<100 where viewModel.overviewItems.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProviderSelected(true, providerID: rule.id)
        viewModel.requestOverviewCleanup()
        for _ in 0..<100 where viewModel.frozenOverviewPlan == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.performOverviewCleanup()
        for _ in 0..<100 where await overviewScanner.scanCount < 2 || viewModel.isCleaning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await overviewScanner.scanCount == 2)
        #expect(viewModel.lastOverviewCleanupReport?.outcomes.map(\.status) == [.cleaned, .failed])
        #expect(viewModel.errorMessage != nil)
        #expect(await historyStore.recordCount == 1)
    }

    private func makeResult() -> CleanupScanResult {
        CleanupScanResult(
            rule: .xcodeDerivedData,
            items: [
                CleanupItem(
                    id: "first",
                    providerID: CleanupRule.xcodeDerivedData.id,
                    stableIdentity: "/tmp/first",
                    displayName: "First",
                    url: URL(filePath: "/tmp/first"),
                    discoveredAt: Date(timeIntervalSince1970: 2_000_000_000),
                    modifiedAt: nil,
                    resourceIdentifier: nil,
                    allocatedSize: 100,
                    cleanupPolicy: .permanentDelete
                ),
                CleanupItem(
                    id: "second",
                    providerID: CleanupRule.xcodeDerivedData.id,
                    stableIdentity: "/tmp/second",
                    displayName: "Second",
                    url: URL(filePath: "/tmp/second"),
                    discoveredAt: Date(timeIntervalSince1970: 2_000_000_000),
                    modifiedAt: nil,
                    resourceIdentifier: nil,
                    allocatedSize: 200,
                    cleanupPolicy: .permanentDelete
                )
            ],
            scannedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    private struct DelayedScanner: CleanupScanning {
        func scan(
            rule: CleanupRule,
            olderThanDays: Int,
            now: Date
        ) async throws -> CleanupScanResult {
            if rule.id == CleanupRule.defenderDiagnostics.id {
                try? await Task.sleep(for: .milliseconds(300))
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }

            return CleanupScanResult(
                rule: rule,
                items: [
                    CleanupItem(
                        id: rule.id,
                        providerID: rule.id,
                        stableIdentity: rule.id,
                        displayName: rule.name,
                        url: nil,
                        discoveredAt: now,
                        modifiedAt: nil,
                        resourceIdentifier: nil,
                        allocatedSize: 1,
                        cleanupPolicy: rule.cleanupPolicy
                    )
                ],
                scannedAt: now
            )
        }
    }

    private func makeOverviewRule() -> CleanupRule {
        CleanupRule(
            id: "overview-fixture",
            name: "Overview Fixture",
            summary: "Fixture overview provider",
            locations: [],
            supportsRetention: false,
            systemImage: "shippingbox",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .permanentDeleteContents,
                isRegenerable: true,
                requiresPrivilege: false,
                consequence: "Fixture consequence"
            ),
            managedLocationDescription: "Fixture-managed",
            cleanupUnavailableReason: nil
        )
    }

    private func makeOverviewItem(id: String, rule: CleanupRule, bytes: Int64) -> CleanupItem {
        CleanupItem(
            id: id,
            providerID: rule.id,
            stableIdentity: id,
            displayName: id,
            url: nil,
            discoveredAt: Date(timeIntervalSince1970: 2_000_000_000),
            modifiedAt: nil,
            resourceIdentifier: nil,
            allocatedSize: bytes,
            cleanupPolicy: rule.cleanupPolicy
        )
    }
}

private actor CountingScanner: CleanupScanning {
    private(set) var scanCount = 0
    private let result: CleanupScanResult

    init(result: CleanupScanResult) {
        self.result = result
    }

    func scan(
        rule: CleanupRule,
        olderThanDays days: Int,
        now: Date
    ) async throws -> CleanupScanResult {
        scanCount += 1
        return result
    }
}

@MainActor
private struct PartialFailureCleaner: CleanupExecuting {
    func clean(rule: CleanupRule, items: [CleanupItem]) async -> CleanupReport {
        CleanupReport(
            outcomes: [
                CleanupItemOutcome(
                    itemID: items[0].id,
                    displayName: items[0].displayName,
                    status: .cleaned,
                    message: nil
                ),
                CleanupItemOutcome(
                    itemID: items[1].id,
                    displayName: items[1].displayName,
                    status: .failed,
                    message: "Fixture failure"
                )
            ]
        )
    }
}

/// Always resolves immediately: unit tests must never depend on
/// `mdatp` or any other real system tool being installed.
private struct ImmediateHealthyMonitor: DefenderHealthMonitoring {
    func currentStatus() async -> DefenderHealthStatus {
        .healthy
    }
}

private actor RecordingHealthMonitor: DefenderHealthMonitoring {
    private(set) var callCount = 0
    private let status: DefenderHealthStatus

    init(status: DefenderHealthStatus) {
        self.status = status
    }

    func currentStatus() async -> DefenderHealthStatus {
        callCount += 1
        return status
    }
}

private actor CountingOverviewScanner: OverviewScanning {
    let rules: [CleanupRule]
    private let result: OverviewProviderResult
    private(set) var scanCount = 0

    init(result: OverviewProviderResult) {
        self.rules = [result.rule]
        self.result = result
    }

    func scanAll(
        retentionDaysByProviderID: [String: Int],
        now: Date,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewScanSnapshot {
        scanCount += 1
        let currentResult = OverviewProviderResult(
            rule: result.rule,
            items: result.items,
            scannedAt: now,
            status: result.status,
            warnings: result.warnings,
            safeItemIDs: result.safeItemIDs,
            retentionDays: result.retentionDays
        )
        await progress(currentResult)
        return OverviewScanSnapshot(
            providers: [currentResult],
            startedAt: now,
            completedAt: now
        )
    }

    func makeCleanupPlan(
        selections: Set<OverviewItemID>,
        snapshot: OverviewScanSnapshot
    ) async -> CrossProviderCleanupPlan {
        let selectedItems = snapshot.providers
            .flatMap(\.items)
            .filter { selections.contains(OverviewItemID(providerID: $0.providerID, itemID: $0.id)) }
        return CrossProviderCleanupPlan(
            providerPlans: [
                CleanupExecutionPlan(
                    providerID: result.rule.id,
                    items: selectedItems,
                    createdAt: .now
                )
            ],
            rulesByProviderID: [result.rule.id: result.rule],
            createdAt: .now
        )
    }
}

private struct PartialFailureOverviewCleaner: OverviewCleanupExecuting {
    func execute(
        plan: CrossProviderCleanupPlan,
        progress: @escaping @Sendable (OverviewCleanupProgress) async -> Void
    ) async -> CrossProviderCleanupReport {
        let itemStates = Dictionary(
            uniqueKeysWithValues: plan.items.enumerated().map { index, item in
                let status: CleanupOutcomeStatus = index == 0 ? .cleaned : .failed
                return (
                    OverviewItemID(providerID: item.providerID, itemID: item.id),
                    OverviewCleanupItemState.finished(status)
                )
            }
        )
        await progress(
            OverviewCleanupProgress(
                providerID: plan.providerPlans.first?.providerID,
                itemStates: itemStates,
                completedItems: plan.items.count,
                totalItems: plan.items.count,
                isCancelling: false
            )
        )
        let itemsByID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0) })
        let outcomes = plan.items.enumerated().map { index, item in
            CleanupItemOutcome(
                itemID: item.id,
                displayName: item.displayName,
                status: index == 0 ? .cleaned : .failed,
                message: index == 0 ? nil : "Fixture failure"
            )
        }
        let providerID = plan.providerPlans.first?.providerID ?? "fixture"
        return CrossProviderCleanupReport(
            providerReports: [
                ProviderCleanupReport(
                    providerID: providerID,
                    outcomes: outcomes,
                    itemsByID: itemsByID
                )
            ],
            startedAt: .now,
            completedAt: .now
        )
    }
}

private actor RecordingOverviewHistoryStore: CleanupHistoryStoring {
    private(set) var recordCount = 0

    func load() async -> [CleanupHistoryEntry] {
        []
    }

    func record(report: CrossProviderCleanupReport, plan: CrossProviderCleanupPlan) async {
        recordCount += 1
    }
}
