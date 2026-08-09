import Foundation

protocol OverviewScanning: Sendable {
    var rules: [CleanupRule] { get }

    func scanAll(
        retentionDaysByProviderID: [String: Int],
        now: Date,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewScanSnapshot

    func makeCleanupPlan(
        selections: Set<OverviewItemID>,
        snapshot: OverviewScanSnapshot
    ) async -> CrossProviderCleanupPlan
}

actor OverviewScanCoordinator: OverviewScanning {
    let rules: [CleanupRule]

    private let catalog: CleanupProviderCatalog
    private let runningApplicationChecker: any RunningApplicationChecking
    private let maximumConcurrentProviders: Int

    init(
        catalog: CleanupProviderCatalog = .builtIn,
        runningApplicationChecker: any RunningApplicationChecking = RunningApplicationChecker(),
        maximumConcurrentProviders: Int = 3
    ) {
        self.catalog = catalog
        self.rules = catalog.rules
        self.runningApplicationChecker = runningApplicationChecker
        self.maximumConcurrentProviders = max(1, maximumConcurrentProviders)
    }

    func scanAll(
        retentionDaysByProviderID: [String: Int],
        now: Date,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewScanSnapshot {
        let startedAt = now
        let providers = catalog.providers
        var iterator = providers.makeIterator()
        var results: [OverviewProviderResult] = []

        await withTaskGroup(of: OverviewProviderResult.self) { group in
            for _ in 0..<min(maximumConcurrentProviders, providers.count) {
                if let provider = iterator.next() {
                    group.addTask {
                        await Self.scan(
                            provider: provider,
                            retentionDays: retentionDaysByProviderID[provider.rule.id]
                                ?? provider.rule.defaultRetentionDays
                                ?? 30,
                            now: now,
                            runningApplicationChecker: self.runningApplicationChecker,
                            progress: progress
                        )
                    }
                }
            }

            while let result = await group.next() {
                results.append(result)
                if !Task.isCancelled, let provider = iterator.next() {
                    group.addTask {
                        await Self.scan(
                            provider: provider,
                            retentionDays: retentionDaysByProviderID[provider.rule.id]
                                ?? provider.rule.defaultRetentionDays
                                ?? 30,
                            now: now,
                            runningApplicationChecker: self.runningApplicationChecker,
                            progress: progress
                        )
                    }
                }
            }
        }

        let order = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        results.sort { order[$0.rule.id, default: .max] < order[$1.rule.id, default: .max] }
        return OverviewScanSnapshot(providers: results, startedAt: startedAt, completedAt: .now)
    }

    func makeCleanupPlan(
        selections: Set<OverviewItemID>,
        snapshot: OverviewScanSnapshot
    ) async -> CrossProviderCleanupPlan {
        var plans: [CleanupExecutionPlan] = []
        var rulesByProviderID: [String: CleanupRule] = [:]

        for providerResult in snapshot.providers {
            let selectedItems = providerResult.items.filter {
                selections.contains(OverviewItemID(providerID: $0.providerID, itemID: $0.id))
            }
            guard !selectedItems.isEmpty,
                  let provider = catalog.provider(id: providerResult.id) else {
                continue
            }
            plans.append(await provider.makeExecutionPlan(items: selectedItems))
            rulesByProviderID[providerResult.id] = providerResult.rule
        }

        return CrossProviderCleanupPlan(
            providerPlans: plans,
            rulesByProviderID: rulesByProviderID,
            createdAt: .now
        )
    }

    private static func scan(
        provider: any CleanupProvider,
        retentionDays: Int,
        now: Date,
        runningApplicationChecker: any RunningApplicationChecking,
        progress: @escaping @Sendable (OverviewProviderResult) async -> Void
    ) async -> OverviewProviderResult {
        let rule = provider.previewMetadata
        await progress(
            OverviewProviderResult(
                rule: rule,
                items: [],
                scannedAt: nil,
                status: .scanning,
                warnings: [],
                safeItemIDs: [],
                retentionDays: rule.supportsRetention ? retentionDays : nil
            )
        )

        let unavailableReason: String?
        switch provider.availability {
        case .unavailable(let reason):
            unavailableReason = reason
        case .available:
            unavailableReason = nil
        }

        do {
            let scanResult = try await provider.scan(olderThanDays: retentionDays, now: now)
            try Task.checkCancellation()

            let applications = await runningApplicationChecker.runningApplicationNames(
                bundleIdentifiers: provider.runningApplicationBehavior.bundleIdentifiers,
                names: provider.runningApplicationBehavior.processNames
            )
            let runningWarning = applications.isEmpty
                ? nil
                : "Quit \(applications.sorted().joined(separator: ", ")), rescan, and try again."

            var safeItemIDs: Set<OverviewItemID> = []
            if unavailableReason == nil,
               runningWarning == nil,
               provider.safetyMetadata.isRegenerable
                    || provider.safetyMetadata.cleanupPolicy == .moveToTrash {
                for item in scanResult.items {
                    do {
                        try await provider.validate(item)
                        safeItemIDs.insert(OverviewItemID(providerID: rule.id, itemID: item.id))
                    } catch {
                        continue
                    }
                }
            }

            var warnings = scanResult.items.compactMap(\.notice)
            if let unavailableReason {
                warnings.insert(unavailableReason, at: 0)
            }
            if let runningWarning {
                warnings.insert(runningWarning, at: 0)
            }
            if let caution = rule.caution {
                warnings.append(caution)
            }

            let result = OverviewProviderResult(
                rule: scanResult.rule,
                items: scanResult.items,
                scannedAt: scanResult.scannedAt,
                status: unavailableReason.map(OverviewProviderScanStatus.unavailable) ?? .available,
                warnings: Array(Set(warnings)).sorted(),
                safeItemIDs: safeItemIDs,
                retentionDays: rule.supportsRetention ? retentionDays : nil
            )
            await progress(result)
            return result
        } catch is CancellationError {
            return OverviewProviderResult(
                rule: rule,
                items: [],
                scannedAt: nil,
                status: .failed("Scan cancelled."),
                warnings: [],
                safeItemIDs: [],
                retentionDays: rule.supportsRetention ? retentionDays : nil
            )
        } catch {
            let presentation = UserFacingError.scan(error, categoryName: rule.name)
            let result = OverviewProviderResult(
                rule: rule,
                items: [],
                scannedAt: now,
                status: .failed(presentation.alertMessage),
                warnings: [presentation.alertMessage],
                safeItemIDs: [],
                technicalDetails: presentation.technicalDetails,
                retentionDays: rule.supportsRetention ? retentionDays : nil
            )
            await progress(result)
            return result
        }
    }
}

protocol OverviewCleanupExecuting: Sendable {
    func execute(
        plan: CrossProviderCleanupPlan,
        progress: @escaping @Sendable (OverviewCleanupProgress) async -> Void
    ) async -> CrossProviderCleanupReport
}

actor OverviewCleanupExecutor: OverviewCleanupExecuting {
    private let catalog: CleanupProviderCatalog

    init(catalog: CleanupProviderCatalog = .builtIn) {
        self.catalog = catalog
    }

    func execute(
        plan: CrossProviderCleanupPlan,
        progress: @escaping @Sendable (OverviewCleanupProgress) async -> Void
    ) async -> CrossProviderCleanupReport {
        let startedAt = Date.now
        let allItems = plan.providerPlans.flatMap(\.items)
        var states: [OverviewItemID: OverviewCleanupItemState] = Dictionary(
            uniqueKeysWithValues: allItems.map {
                (
                    OverviewItemID(providerID: $0.providerID, itemID: $0.id),
                    OverviewCleanupItemState.waiting
                )
            }
        )
        var reports: [ProviderCleanupReport] = []
        var completedItems = 0

        await progress(
            OverviewCleanupProgress(
                providerID: nil,
                itemStates: states,
                completedItems: 0,
                totalItems: allItems.count,
                isCancelling: false
            )
        )

        for providerPlan in plan.providerPlans {
            if Task.isCancelled {
                break
            }

            for item in providerPlan.items {
                states[OverviewItemID(providerID: item.providerID, itemID: item.id)] =
                    OverviewCleanupItemState.running
            }
            await progress(
                OverviewCleanupProgress(
                    providerID: providerPlan.providerID,
                    itemStates: states,
                    completedItems: completedItems,
                    totalItems: allItems.count,
                    isCancelling: false
                )
            )

            let report: CleanupReport
            if let provider = catalog.provider(id: providerPlan.providerID) {
                report = await provider.execute(plan: providerPlan)
            } else {
                report = CleanupReport(outcomes: providerPlan.items.map {
                    CleanupItemOutcome(
                        itemID: $0.id,
                        displayName: $0.displayName,
                        status: .failed,
                        message: CleanupProviderError.providerNotRegistered(
                            providerPlan.providerID
                        ).localizedDescription
                    )
                })
            }

            let outcomeByID = Dictionary(
                report.outcomes.map { ($0.itemID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for item in providerPlan.items {
                let outcome = outcomeByID[item.id] ?? CleanupItemOutcome(
                    itemID: item.id,
                    displayName: item.displayName,
                    status: Task.isCancelled ? .cancelled : .failed,
                    message: Task.isCancelled ? "Cancelled." : "No outcome was returned."
                )
                states[OverviewItemID(providerID: item.providerID, itemID: item.id)] =
                    OverviewCleanupItemState.finished(outcome.status)
                completedItems += 1
            }
            reports.append(
                ProviderCleanupReport(
                    providerID: providerPlan.providerID,
                    outcomes: report.outcomes,
                    itemsByID: Dictionary(
                        providerPlan.items.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            )
            await progress(
                OverviewCleanupProgress(
                    providerID: providerPlan.providerID,
                    itemStates: states,
                    completedItems: completedItems,
                    totalItems: allItems.count,
                    isCancelling: Task.isCancelled
                )
            )
        }

        if Task.isCancelled {
            for providerPlan in plan.providerPlans where
                !reports.contains(where: { $0.providerID == providerPlan.providerID }) {
                let outcomes = providerPlan.items.map {
                    CleanupItemOutcome(
                        itemID: $0.id,
                        displayName: $0.displayName,
                        status: .cancelled,
                        message: "Cancelled before this provider started."
                    )
                }
                for item in providerPlan.items {
                    states[OverviewItemID(providerID: item.providerID, itemID: item.id)] =
                        OverviewCleanupItemState.finished(CleanupOutcomeStatus.cancelled)
                    completedItems += 1
                }
                reports.append(
                    ProviderCleanupReport(
                        providerID: providerPlan.providerID,
                        outcomes: outcomes,
                        itemsByID: Dictionary(
                            providerPlan.items.map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                    )
                )
            }
            await progress(
                OverviewCleanupProgress(
                    providerID: nil,
                    itemStates: states,
                    completedItems: completedItems,
                    totalItems: allItems.count,
                    isCancelling: true
                )
            )
        }

        return CrossProviderCleanupReport(
            providerReports: reports,
            startedAt: startedAt,
            completedAt: .now
        )
    }
}
