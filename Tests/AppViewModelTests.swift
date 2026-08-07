import Foundation
import Testing
@testable import SpaceMender

@MainActor
struct AppViewModelTests {
    @Test
    func newResultsStartWithNothingSelected() {
        let viewModel = AppViewModel(result: makeResult())

        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(viewModel.selectedItems.isEmpty)
        #expect(!viewModel.canClean)
    }

    @Test
    func individualSelectionIncludesOnlyRequestedItems() {
        let result = makeResult()
        let viewModel = AppViewModel(result: result)

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
        let viewModel = AppViewModel(result: result)

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
        let viewModel = AppViewModel(result: result)

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
        let viewModel = AppViewModel(result: initial, scanner: scanner, cleaner: cleaner)
        viewModel.selectAll()

        viewModel.performCleanup()

        for _ in 0..<100 where await scanner.scanCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await scanner.scanCount == 1)
        #expect(viewModel.lastCleanupReport?.outcomes.map(\.status) == [.cleaned, .failed])
        #expect(viewModel.errorMessage != nil)
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
    func clean(rule: CleanupRule, items: [CleanupItem]) -> CleanupReport {
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
