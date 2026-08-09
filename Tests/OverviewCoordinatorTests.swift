import Foundation
import Testing
@testable import SpaceMender

struct OverviewCoordinatorTests {
    @Test
    func scansProvidersWithBoundedConcurrencyAndPreservesPartialFailures() async {
        let tracker = ConcurrencyTracker()
        let providers: [any CleanupProvider] = [
            OverviewFixtureProvider(id: "one", tracker: tracker),
            OverviewFixtureProvider(id: "two", tracker: tracker),
            OverviewFixtureProvider(id: "three", tracker: tracker, shouldFail: true),
            OverviewFixtureProvider(id: "four", tracker: tracker)
        ]
        let coordinator = OverviewScanCoordinator(
            catalog: CleanupProviderCatalog(providers: providers),
            runningApplicationChecker: NoOverviewRunningApplications(),
            maximumConcurrentProviders: 2
        )

        let snapshot = await coordinator.scanAll(
            retentionDaysByProviderID: [:],
            now: Date(timeIntervalSince1970: 2_000_000_000),
            progress: { _ in }
        )

        #expect(snapshot.providers.count == 4)
        #expect(snapshot.providers.filter { $0.items.count == 1 }.count == 3)
        #expect(snapshot.providers.contains {
            if case .failed = $0.status { return true }
            return false
        })
        #expect(await tracker.maximumConcurrent == 2)
    }

    @Test
    func safeSelectionUsesProviderMetadataValidationAndRunningConflicts() async throws {
        let safe = OverviewFixtureProvider(id: "safe", tracker: ConcurrencyTracker())
        let unsafe = OverviewFixtureProvider(
            id: "unsafe",
            tracker: ConcurrencyTracker(),
            isRegenerable: false
        )
        let coordinator = OverviewScanCoordinator(
            catalog: CleanupProviderCatalog(providers: [safe, unsafe]),
            runningApplicationChecker: NoOverviewRunningApplications()
        )
        let snapshot = await coordinator.scanAll(
            retentionDaysByProviderID: [:],
            now: .now,
            progress: { _ in }
        )

        #expect(snapshot.providers.first(where: { $0.id == "safe" })?.safeItemIDs.count == 1)
        #expect(snapshot.providers.first(where: { $0.id == "unsafe" })?.safeItemIDs.isEmpty == true)
    }

    @Test
    func trashRecoverableProvidersRemainSafeEvenWhenNotRegenerable() async {
        let trash = OverviewFixtureProvider(
            id: "trash",
            tracker: ConcurrencyTracker(),
            isRegenerable: false,
            policy: .moveToTrash
        )
        let coordinator = OverviewScanCoordinator(
            catalog: CleanupProviderCatalog(providers: [trash]),
            runningApplicationChecker: NoOverviewRunningApplications()
        )

        let snapshot = await coordinator.scanAll(
            retentionDaysByProviderID: [:],
            now: .now,
            progress: { _ in }
        )

        #expect(snapshot.providers.first(where: { $0.id == "trash" })?.safeItemIDs.count == 1)
    }

    @Test
    @MainActor
    func overviewSelectionAndFrozenPlanRemainExact() async throws {
        let scanner = ImmediateOverviewScanner()
        let viewModel = AppViewModel(
            defenderHealthMonitor: OverviewHealthyMonitor(),
            overviewScanner: scanner,
            overviewCleaner: NoopOverviewCleaner(),
            historyStore: InMemoryHistoryStore()
        )
        viewModel.scanOverview()
        for _ in 0..<100 where viewModel.overviewItems.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.overviewSelectedItemIDs.isEmpty)
        let item = try #require(viewModel.overviewItems.first)
        viewModel.setOverviewSelected(true, item: item)
        viewModel.requestOverviewCleanup()
        for _ in 0..<100 where viewModel.frozenOverviewPlan == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let frozenIDs = viewModel.frozenOverviewPlan?.items.map(\.id)

        viewModel.clearOverviewSelection()

        #expect(frozenIDs == [item.id])
        #expect(viewModel.frozenOverviewPlan?.items.map(\.id) == [item.id])
    }

    @Test
    func overviewCleanupProgressAndAggregateOutcomeBytesTrackMixedResults() async {
        let cacheRule = overviewRule(
            id: "cache",
            isRegenerable: true,
            policy: .permanentDeleteContents
        )
        let logsRule = overviewRule(
            id: "logs",
            isRegenerable: false,
            policy: .moveToTrash
        )
        let helperRule = overviewRule(
            id: "helper",
            isRegenerable: false,
            policy: .permanentDelete
        )
        let cacheItem = overviewItem(
            providerID: cacheRule.id,
            id: "cache-item",
            path: nil,
            bytes: 10,
            policy: cacheRule.cleanupPolicy
        )
        let logsItem = overviewItem(
            providerID: logsRule.id,
            id: "logs-item",
            path: nil,
            bytes: 5,
            policy: logsRule.cleanupPolicy
        )
        let helperItem = overviewItem(
            providerID: helperRule.id,
            id: "helper-item",
            path: nil,
            bytes: 7,
            policy: helperRule.cleanupPolicy
        )
        let providers: [any CleanupProvider] = [
            ScriptedCleanupProvider(
                rule: cacheRule,
                items: [cacheItem],
                outcomes: [FixtureOutcome(status: .cleaned)]
            ),
            ScriptedCleanupProvider(
                rule: logsRule,
                items: [logsItem],
                outcomes: [FixtureOutcome(status: .movedToTrash)]
            ),
            ScriptedCleanupProvider(
                rule: helperRule,
                items: [helperItem],
                outcomes: [FixtureOutcome(status: .failed, message: "Fixture failure")]
            )
        ]
        let plan = CrossProviderCleanupPlan(
            providerPlans: [
                CleanupExecutionPlan(providerID: cacheRule.id, items: [cacheItem], createdAt: .now),
                CleanupExecutionPlan(providerID: logsRule.id, items: [logsItem], createdAt: .now),
                CleanupExecutionPlan(providerID: helperRule.id, items: [helperItem], createdAt: .now)
            ],
            rulesByProviderID: [
                cacheRule.id: cacheRule,
                logsRule.id: logsRule,
                helperRule.id: helperRule
            ],
            createdAt: .now
        )
        let recorder = ProgressRecorder()
        let executor = OverviewCleanupExecutor(
            catalog: CleanupProviderCatalog(providers: providers)
        )

        let report = await executor.execute(plan: plan) { progress in
            await recorder.record(progress)
        }
        let snapshots = await recorder.allSnapshots()
        let cacheID = OverviewItemID(providerID: cacheRule.id, itemID: cacheItem.id)
        let logsID = OverviewItemID(providerID: logsRule.id, itemID: logsItem.id)
        let helperID = OverviewItemID(providerID: helperRule.id, itemID: helperItem.id)

        #expect(report.permanentlyReclaimedBytes == 10)
        #expect(report.movedToTrashBytes == 5)
        #expect(report.hasFailures)
        #expect(snapshots.first?.completedItems == 0)
        #expect(snapshots.first?.itemStates[cacheID] == .waiting)
        #expect(snapshots.contains { snapshot in
            snapshot.providerID == cacheRule.id
                && snapshot.itemStates[cacheID] == .running
                && snapshot.itemStates[logsID] == .waiting
        })
        #expect(snapshots.contains { snapshot in
            snapshot.providerID == logsRule.id
                && snapshot.itemStates[cacheID] == .finished(.cleaned)
                && snapshot.itemStates[logsID] == .running
        })
        #expect(snapshots.last?.completedItems == 3)
        #expect(snapshots.last?.itemStates[helperID] == .finished(.failed))
    }

    @Test
    func historyPersistsOnlyProviderOutcomeAndSizeMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "history.json")
        let store = CleanupHistoryStore(fileURL: fileURL)
        let item = overviewItem(
            providerID: "safe",
            id: "secret-item",
            path: "/Users/person/Library/Logs/private-name.log",
            bytes: 42,
            policy: .moveToTrash
        )
        let rule = overviewRule(id: "safe", isRegenerable: false, policy: .moveToTrash)
        let plan = CrossProviderCleanupPlan(
            providerPlans: [
                CleanupExecutionPlan(providerID: rule.id, items: [item], createdAt: .now)
            ],
            rulesByProviderID: [rule.id: rule],
            createdAt: .now
        )
        let report = CrossProviderCleanupReport(
            providerReports: [
                ProviderCleanupReport(
                    providerID: rule.id,
                    outcomes: [
                        CleanupItemOutcome(
                            itemID: item.id,
                            displayName: item.displayName,
                            status: .movedToTrash,
                            message: nil
                        )
                    ],
                    itemsByID: [item.id: item]
                )
            ],
            startedAt: .now,
            completedAt: .now
        )

        await store.record(report: report, plan: plan)
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let entries = await store.load()

        #expect(entries.count == 1)
        #expect(entries[0].movedToTrashBytes == 42)
        #expect(!text.contains("/Users/person"))
        #expect(!text.contains("private-name.log"))
        #expect(!text.contains("secret-item"))
    }

    @Test
    func historyClassifiesSucceededPartialFailedAndCancelledProviders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleanupHistoryStore(fileURL: directory.appending(path: "history.json"))
        let successRule = overviewRule(
            id: "success",
            isRegenerable: true,
            policy: .permanentDeleteContents
        )
        let partialRule = overviewRule(
            id: "partial",
            isRegenerable: false,
            policy: .moveToTrash
        )
        let failedRule = overviewRule(
            id: "failed",
            isRegenerable: false,
            policy: .permanentDeleteContents
        )
        let cancelledRule = overviewRule(
            id: "cancelled",
            isRegenerable: false,
            policy: .permanentDeleteContents
        )
        let successItem = overviewItem(
            providerID: successRule.id,
            id: "success-item",
            path: nil,
            bytes: 10,
            policy: successRule.cleanupPolicy
        )
        let partialTrashItem = overviewItem(
            providerID: partialRule.id,
            id: "partial-trash",
            path: nil,
            bytes: 20,
            policy: partialRule.cleanupPolicy
        )
        let partialFailedItem = overviewItem(
            providerID: partialRule.id,
            id: "partial-failed",
            path: nil,
            bytes: 30,
            policy: partialRule.cleanupPolicy
        )
        let failedItem = overviewItem(
            providerID: failedRule.id,
            id: "failed-item",
            path: nil,
            bytes: 40,
            policy: failedRule.cleanupPolicy
        )
        let cancelledItem = overviewItem(
            providerID: cancelledRule.id,
            id: "cancelled-item",
            path: nil,
            bytes: 50,
            policy: cancelledRule.cleanupPolicy
        )
        let plan = CrossProviderCleanupPlan(
            providerPlans: [
                CleanupExecutionPlan(providerID: successRule.id, items: [successItem], createdAt: .now),
                CleanupExecutionPlan(
                    providerID: partialRule.id,
                    items: [partialTrashItem, partialFailedItem],
                    createdAt: .now
                ),
                CleanupExecutionPlan(providerID: failedRule.id, items: [failedItem], createdAt: .now),
                CleanupExecutionPlan(
                    providerID: cancelledRule.id,
                    items: [cancelledItem],
                    createdAt: .now
                )
            ],
            rulesByProviderID: [
                successRule.id: successRule,
                partialRule.id: partialRule,
                failedRule.id: failedRule,
                cancelledRule.id: cancelledRule
            ],
            createdAt: .now
        )
        let report = CrossProviderCleanupReport(
            providerReports: [
                ProviderCleanupReport(
                    providerID: successRule.id,
                    outcomes: [
                        CleanupItemOutcome(
                            itemID: successItem.id,
                            displayName: successItem.displayName,
                            status: .cleaned,
                            message: nil
                        )
                    ],
                    itemsByID: [successItem.id: successItem]
                ),
                ProviderCleanupReport(
                    providerID: partialRule.id,
                    outcomes: [
                        CleanupItemOutcome(
                            itemID: partialTrashItem.id,
                            displayName: partialTrashItem.displayName,
                            status: .movedToTrash,
                            message: nil
                        ),
                        CleanupItemOutcome(
                            itemID: partialFailedItem.id,
                            displayName: partialFailedItem.displayName,
                            status: .failed,
                            message: "Fixture failure"
                        )
                    ],
                    itemsByID: [
                        partialTrashItem.id: partialTrashItem,
                        partialFailedItem.id: partialFailedItem
                    ]
                ),
                ProviderCleanupReport(
                    providerID: failedRule.id,
                    outcomes: [
                        CleanupItemOutcome(
                            itemID: failedItem.id,
                            displayName: failedItem.displayName,
                            status: .failed,
                            message: "Fixture failure"
                        )
                    ],
                    itemsByID: [failedItem.id: failedItem]
                ),
                ProviderCleanupReport(
                    providerID: cancelledRule.id,
                    outcomes: [
                        CleanupItemOutcome(
                            itemID: cancelledItem.id,
                            displayName: cancelledItem.displayName,
                            status: .cancelled,
                            message: nil
                        )
                    ],
                    itemsByID: [cancelledItem.id: cancelledItem]
                )
            ],
            startedAt: .now,
            completedAt: .now
        )

        await store.record(report: report, plan: plan)
        let entries = await store.load()
        let byProviderID = Dictionary(uniqueKeysWithValues: entries.map { ($0.providerID, $0) })

        #expect(byProviderID["success"]?.outcome == "Succeeded")
        #expect(byProviderID["success"]?.permanentlyReclaimedBytes == 10)
        #expect(byProviderID["partial"]?.outcome == "Partially succeeded")
        #expect(byProviderID["partial"]?.movedToTrashBytes == 20)
        #expect(byProviderID["failed"]?.outcome == "Failed")
        #expect(byProviderID["cancelled"]?.outcome == "Cancelled")
    }
}

private actor ConcurrencyTracker {
    private var currentConcurrent = 0
    private(set) var maximumConcurrent = 0

    func started() {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
    }

    func finished() {
        currentConcurrent -= 1
    }
}

private actor ProgressRecorder {
    private var snapshots: [OverviewCleanupProgress] = []

    func record(_ progress: OverviewCleanupProgress) {
        snapshots.append(progress)
    }

    func allSnapshots() -> [OverviewCleanupProgress] {
        snapshots
    }
}

private struct OverviewFixtureProvider: CleanupProvider {
    let rule: CleanupRule
    let tracker: ConcurrencyTracker
    let shouldFail: Bool

    init(
        id: String,
        tracker: ConcurrencyTracker,
        shouldFail: Bool = false,
        isRegenerable: Bool = true,
        policy: CleanupPolicy = .permanentDeleteContents
    ) {
        self.rule = overviewRule(
            id: id,
            isRegenerable: isRegenerable,
            policy: policy
        )
        self.tracker = tracker
        self.shouldFail = shouldFail
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        await tracker.started()
        try? await Task.sleep(for: .milliseconds(40))
        await tracker.finished()
        if shouldFail {
            throw FixtureOverviewError.failed
        }
        return [
            overviewItem(
                providerID: rule.id,
                id: "\(rule.id)-item",
                path: nil,
                bytes: 10,
                policy: rule.cleanupPolicy
            )
        ]
    }

    func validate(_ item: CleanupItem) async throws {
        guard item.providerID == rule.id else {
            throw CleanupValidationError.providerMismatch
        }
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        CleanupReport(outcomes: plan.items.map {
            CleanupItemOutcome(
                itemID: $0.id,
                displayName: $0.displayName,
                status: .cleaned,
                message: nil
            )
        })
    }
}

private enum FixtureOverviewError: Error {
    case failed
}

private struct FixtureOutcome {
    let status: CleanupOutcomeStatus
    var message: String? = nil
}

private struct ScriptedCleanupProvider: CleanupProvider {
    let rule: CleanupRule
    let items: [CleanupItem]
    let outcomes: [FixtureOutcome]

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        items
    }

    func validate(_ item: CleanupItem) async throws {
        guard items.contains(where: { $0.id == item.id && $0.providerID == rule.id }) else {
            throw CleanupValidationError.providerMismatch
        }
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        CleanupReport(
            outcomes: Array(zip(plan.items, outcomes)).map { item, outcome in
                CleanupItemOutcome(
                    itemID: item.id,
                    displayName: item.displayName,
                    status: outcome.status,
                    message: outcome.message
                )
            }
        )
    }
}

private struct NoOverviewRunningApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}

private struct ImmediateOverviewScanner: OverviewScanning {
    let rules = [overviewRule(id: "safe", isRegenerable: true, policy: .permanentDeleteContents)]

    func scanAll(
        retentionDaysByProviderID: [String: Int],
        now: Date,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewScanSnapshot {
        let item = overviewItem(
            providerID: rules[0].id,
            id: "selected",
            path: nil,
            bytes: 10,
            policy: rules[0].cleanupPolicy
        )
        let result = OverviewProviderResult(
            rule: rules[0],
            items: [item],
            scannedAt: now,
            status: .available,
            warnings: [],
            safeItemIDs: [OverviewItemID(providerID: item.providerID, itemID: item.id)]
        )
        await progress(result)
        return OverviewScanSnapshot(providers: [result], startedAt: now, completedAt: now)
    }

    func makeCleanupPlan(
        selections: Set<OverviewItemID>,
        snapshot: OverviewScanSnapshot
    ) async -> CrossProviderCleanupPlan {
        let items = snapshot.providers.flatMap(\.items).filter {
            selections.contains(OverviewItemID(providerID: $0.providerID, itemID: $0.id))
        }
        return CrossProviderCleanupPlan(
            providerPlans: [
                CleanupExecutionPlan(providerID: rules[0].id, items: items, createdAt: .now)
            ],
            rulesByProviderID: [rules[0].id: rules[0]],
            createdAt: .now
        )
    }
}

private struct NoopOverviewCleaner: OverviewCleanupExecuting {
    func execute(
        plan: CrossProviderCleanupPlan,
        progress: @escaping @Sendable (OverviewCleanupProgress) async -> Void
    ) async -> CrossProviderCleanupReport {
        CrossProviderCleanupReport(providerReports: [], startedAt: .now, completedAt: .now)
    }
}

private actor InMemoryHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func record(report: CrossProviderCleanupReport, plan: CrossProviderCleanupPlan) async {}
}

private struct OverviewHealthyMonitor: DefenderHealthMonitoring {
    func currentStatus() async -> DefenderHealthStatus { .healthy }
}

private func overviewRule(
    id: String,
    isRegenerable: Bool,
    policy: CleanupPolicy
) -> CleanupRule {
    CleanupRule(
        id: id,
        name: id.capitalized,
        summary: "Fixture",
        locations: [],
        supportsRetention: false,
        systemImage: "testtube.2",
        caution: nil,
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: policy,
            isRegenerable: isRegenerable,
            requiresPrivilege: false,
            consequence: "Fixture consequence"
        ),
        managedLocationDescription: "Fixture",
        cleanupUnavailableReason: nil
    )
}

private func overviewItem(
    providerID: String,
    id: String,
    path: String?,
    bytes: Int64,
    policy: CleanupPolicy
) -> CleanupItem {
    CleanupItem(
        id: id,
        providerID: providerID,
        stableIdentity: id,
        displayName: path.map { URL(filePath: $0).lastPathComponent } ?? id,
        url: path.map { URL(filePath: $0) },
        discoveredAt: .now,
        modifiedAt: nil,
        resourceIdentifier: nil,
        allocatedSize: bytes,
        cleanupPolicy: policy
    )
}
