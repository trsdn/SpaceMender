import AppKit
import Foundation

enum SidebarDestination: Hashable {
    case overview
    case provider(String)
    case history
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var destination: SidebarDestination = .overview
    @Published var selectedRule: CleanupRule = .defenderDiagnostics
    @Published private var retentionDaysByRuleID: [String: Int] = [:]
    @Published private(set) var result: CleanupScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var presentedError: UserFacingError?

    /// Compatibility accessor for tests and non-UI consumers.
    var errorMessage: String? { presentedError?.alertMessage }
    @Published var showingCleanupConfirmation = false
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var lastCleanupReport: CleanupReport?
    @Published private(set) var overviewProviders: [OverviewProviderResult] = []
    @Published private(set) var overviewSelectedItemIDs: Set<OverviewItemID> = []
    @Published private(set) var frozenOverviewPlan: CrossProviderCleanupPlan?
    @Published private(set) var overviewCleanupProgress: OverviewCleanupProgress?
    @Published private(set) var lastOverviewCleanupReport: CrossProviderCleanupReport?
    @Published private(set) var cleanupHistory: [CleanupHistoryEntry] = []
    @Published var showingOverviewConfirmation = false
    /// Microsoft Defender's own real-time-protection health state.
    /// Refreshed independently of scanning and cleanup, and never derived
    /// from or reset by a cleanup outcome: a successful diagnostic-archive
    /// cleanup must never be mistaken for having fixed a Defender health
    /// problem, and a Defender health problem must never block or alter
    /// archive cleanup.
    @Published private(set) var defenderHealth: DefenderHealthStatus?

    @Published private(set) var rules: [CleanupRule]

    private let scanner: any CleanupScanning
    private let cleaner: any CleanupExecuting
    private let defenderHealthMonitor: any DefenderHealthMonitoring
    private let overviewScanner: any OverviewScanning
    private let overviewCleaner: any OverviewCleanupExecuting
    private let historyStore: any CleanupHistoryStoring
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var overviewScanTask: Task<Void, Never>?
    private var overviewCleanupTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(
        result: CleanupScanResult? = nil,
        catalog: CleanupProviderCatalog? = nil,
        scanner: (any CleanupScanning)? = nil,
        cleaner: (any CleanupExecuting)? = nil,
        defenderHealthMonitor: any DefenderHealthMonitoring = MDATPHealthMonitor(),
        overviewScanner: (any OverviewScanning)? = nil,
        overviewCleaner: (any OverviewCleanupExecuting)? = nil,
        historyStore: any CleanupHistoryStoring = CleanupHistoryStore()
    ) {
        // One catalog for the whole app. Providers such as the npm cache
        // provider carry discovery results in instance state and validate
        // against them, so the instance that scans must be the very same
        // instance that later validates and executes. Default-constructing
        // each service would mint a separate catalog — and separate provider
        // objects — silently breaking that hand-off.
        let sharedCatalog = catalog ?? .builtIn()
        let resolvedScanner = scanner ?? CleanupScanner(catalog: sharedCatalog)
        let resolvedCleaner = cleaner ?? CleanupExecutor(catalog: sharedCatalog)
        let resolvedOverviewScanner = overviewScanner
            ?? OverviewScanCoordinator(catalog: sharedCatalog)
        let resolvedOverviewCleaner = overviewCleaner
            ?? OverviewCleanupExecutor(catalog: sharedCatalog)

        self.result = result
        self.scanner = resolvedScanner
        self.cleaner = resolvedCleaner
        self.defenderHealthMonitor = defenderHealthMonitor
        self.overviewScanner = resolvedOverviewScanner
        self.overviewCleaner = resolvedOverviewCleaner
        self.historyStore = historyStore
        self.rules = resolvedOverviewScanner.rules
        self.overviewProviders = resolvedOverviewScanner.rules.map {
            OverviewProviderResult(
                rule: $0,
                items: [],
                scannedAt: nil,
                status: .waiting,
                warnings: [],
                safeItemIDs: []
            )
        }
        if let result {
            selectedRule = result.rule
        }
    }

    var items: [CleanupItem] {
        result?.items ?? []
    }

    var reclaimableBytes: Int64 {
        result?.reclaimableBytes ?? 0
    }

    var selectedItems: [CleanupItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + max(0, $1.allocatedSize) }
    }

    var canClean: Bool {
        !selectedItemIDs.isEmpty
            && selectedRule.cleanupUnavailableReason == nil
            && !isScanning
            && !isCleaning
    }

    var allItemsSelected: Bool {
        !items.isEmpty && selectedItemIDs.count == items.count
    }

    var overviewItems: [CleanupItem] {
        overviewProviders.flatMap(\.items)
    }

    var overviewSelectedItems: [CleanupItem] {
        overviewItems.filter {
            overviewSelectedItemIDs.contains(
                OverviewItemID(providerID: $0.providerID, itemID: $0.id)
            )
        }
    }

    var overviewSelectedBytes: Int64 {
        overviewSelectedItems.reduce(0) { $0 + max(0, $1.allocatedSize) }
    }

    var overviewSafeItemIDs: Set<OverviewItemID> {
        overviewProviders.reduce(into: []) { $0.formUnion($1.safeItemIDs) }
    }

    var canCleanOverview: Bool {
        !overviewSelectedItemIDs.isEmpty && !isScanning && !isCleaning
    }

    /// Each provider's retention age is tracked independently and defaults
    /// to that provider's own declared default (see
    /// `CleanupRule.defaultRetentionDays`), so switching categories never
    /// leaks one provider's chosen age into another.
    var retentionDays: Int {
        get {
            retentionDaysByRuleID[selectedRule.id] ?? (selectedRule.defaultRetentionDays ?? 30)
        }
        set {
            retentionDaysByRuleID[selectedRule.id] = newValue
        }
    }

    func scan(clearError: Bool = true) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        if clearError {
            presentedError = nil
        }

        let rule = selectedRule
        let days = retentionDays
        if rule.id == CleanupRule.defenderDiagnostics.id {
            refreshDefenderHealth()
        }
        scanTask = Task {
            do {
                let scanResult = try await scanner.scan(
                    rule: rule,
                    olderThanDays: days,
                    now: .now
                )
                guard !Task.isCancelled, generation == scanGeneration else {
                    return
                }
                result = scanResult
                selectedRule = scanResult.rule
                if let index = rules.firstIndex(where: { $0.id == scanResult.rule.id }) {
                    rules[index] = scanResult.rule
                }
                selectedItemIDs = []
            } catch {
                guard !Task.isCancelled, generation == scanGeneration else {
                    return
                }
                result = nil
                selectedItemIDs = []
                presentedError = .scan(error, categoryName: rule.name)
            }
            if generation == scanGeneration {
                isScanning = false
            }
        }

    }

    func scanOverview(clearError: Bool = true) {
        overviewScanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        overviewSelectedItemIDs = []
        frozenOverviewPlan = nil
        if clearError {
            presentedError = nil
        }
        overviewProviders = overviewScanner.rules.map {
            OverviewProviderResult(
                rule: $0,
                items: [],
                scannedAt: nil,
                status: .waiting,
                warnings: [],
                safeItemIDs: []
            )
        }
        let retention = retentionDaysByRuleID

        overviewScanTask = Task {
            let snapshot = await overviewScanner.scanAll(
                retentionDaysByProviderID: retention,
                now: .now
            ) { [weak self] providerResult in
                await MainActor.run {
                    guard let self, generation == self.scanGeneration else {
                        return
                    }
                    self.replaceOverviewProvider(providerResult)
                }
            }
            guard !Task.isCancelled, generation == scanGeneration else {
                return
            }
            overviewProviders = snapshot.providers
            isScanning = false
        }
    }

    /// Refreshes Defender's own health state on its own, independent task.
    /// This never reads or writes `result`, `lastCleanupReport`, or any
    /// cleanup outcome, and cleanup never calls this method.
    func refreshDefenderHealth() {
        healthTask?.cancel()
        healthTask = Task {
            let status = await defenderHealthMonitor.currentStatus()
            guard !Task.isCancelled else {
                return
            }
            defenderHealth = status
        }
    }

    func requestCleanup() {
        guard canClean else {
            return
        }
        showingCleanupConfirmation = true
    }

    func isSelected(_ item: CleanupItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func setSelected(_ selected: Bool, item: CleanupItem) {
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    func selectAll() {
        selectedItemIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs = []
    }

    func isOverviewSelected(_ item: CleanupItem) -> Bool {
        overviewSelectedItemIDs.contains(
            OverviewItemID(providerID: item.providerID, itemID: item.id)
        )
    }

    func setOverviewSelected(_ selected: Bool, item: CleanupItem) {
        let id = OverviewItemID(providerID: item.providerID, itemID: item.id)
        if selected {
            overviewSelectedItemIDs.insert(id)
        } else {
            overviewSelectedItemIDs.remove(id)
        }
    }

    func setProviderSelected(_ selected: Bool, providerID: String) {
        let ids = overviewProviders.first(where: { $0.id == providerID })?.items.map {
            OverviewItemID(providerID: $0.providerID, itemID: $0.id)
        } ?? []
        if selected {
            overviewSelectedItemIDs.formUnion(ids)
        } else {
            overviewSelectedItemIDs.subtract(ids)
        }
    }

    func isProviderSelected(_ providerID: String) -> Bool {
        guard let items = overviewProviders.first(where: { $0.id == providerID })?.items,
              !items.isEmpty else {
            return false
        }
        return items.allSatisfy(isOverviewSelected)
    }

    func selectAllSafe() {
        overviewSelectedItemIDs = overviewSafeItemIDs
    }

    func clearOverviewSelection() {
        overviewSelectedItemIDs = []
    }

    func requestOverviewCleanup() {
        guard canCleanOverview else {
            return
        }
        let selections = overviewSelectedItemIDs
        let snapshot = OverviewScanSnapshot(
            providers: overviewProviders,
            startedAt: overviewProviders.compactMap(\.scannedAt).min() ?? .now,
            completedAt: .now
        )
        Task {
            let plan = await overviewScanner.makeCleanupPlan(
                selections: selections,
                snapshot: snapshot
            )
            guard !plan.items.isEmpty else {
                return
            }
            frozenOverviewPlan = plan
            showingOverviewConfirmation = true
        }
    }

    func performOverviewCleanup() {
        guard let plan = frozenOverviewPlan, !plan.items.isEmpty else {
            return
        }
        isCleaning = true
        showingOverviewConfirmation = false
        presentedError = nil
        overviewCleanupTask = Task {
            let report = await overviewCleaner.execute(plan: plan) { [weak self] progress in
                await MainActor.run {
                    self?.overviewCleanupProgress = progress
                }
            }
            lastOverviewCleanupReport = report
            await historyStore.record(report: report, plan: plan)
            cleanupHistory = await historyStore.load()
            if report.hasFailures {
                presentedError = UserFacingError(
                    message: String(localized: "Some selected items couldn’t be cleaned."),
                    recoverySuggestion: String(localized: "Review the cleanup results, then rescan before trying again."),
                    technicalDetails: report.outcomes.compactMap(\.technicalDetails).first
                )
            }
            isCleaning = false
            scanOverview(clearError: false)
        }
    }

    func cancelOverviewCleanup() {
        overviewCleanupTask?.cancel()
    }

    func loadHistory() {
        Task {
            cleanupHistory = await historyStore.load()
        }
    }

    func openTrashInFinder() {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash", directoryHint: .isDirectory)
        NSWorkspace.shared.open(trash)
    }

    func performCleanup() {
        let candidates = selectedItems
        guard !candidates.isEmpty else {
            return
        }

        isCleaning = true
        presentedError = nil
        showingCleanupConfirmation = false

        let rule = selectedRule
        cleanupTask = Task {
            let report = await cleaner.clean(rule: rule, items: candidates)
            lastCleanupReport = report
            if report.hasFailures {
                presentedError = UserFacingError(
                    message: String(localized: "Some selected items couldn’t be cleaned."),
                    recoverySuggestion: String(localized: "Review the cleanup results, then rescan before trying again."),
                    technicalDetails: report.outcomes.compactMap(\.technicalDetails).first
                )
            }
            isCleaning = false
            scan(clearError: false)
        }
    }

    private func replaceOverviewProvider(_ result: OverviewProviderResult) {
        if let index = overviewProviders.firstIndex(where: { $0.id == result.id }) {
            overviewProviders[index] = result
        } else {
            overviewProviders.append(result)
        }
    }
}
