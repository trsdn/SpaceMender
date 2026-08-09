import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedRule: CleanupRule = .defenderDiagnostics
    @Published var retentionDays = 30
    @Published private(set) var result: CleanupScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var errorMessage: String?
    @Published var showingCleanupConfirmation = false
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var lastCleanupReport: CleanupReport?

    @Published private(set) var rules = CleanupRule.builtIn

    private let scanner: any CleanupScanning
    private let cleaner: any CleanupExecuting
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(
        result: CleanupScanResult? = nil,
        scanner: any CleanupScanning = CleanupScanner(),
        cleaner: any CleanupExecuting = CleanupExecutor()
    ) {
        self.result = result
        self.scanner = scanner
        self.cleaner = cleaner
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
        selectedItems.reduce(0) { $0 + $1.allocatedSize }
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

    func scan(clearError: Bool = true) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        if clearError {
            errorMessage = nil
        }

        let rule = selectedRule
        let days = retentionDays
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
                errorMessage = error.localizedDescription
            }
            if generation == scanGeneration {
                isScanning = false
            }
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

    func performCleanup() {
        let candidates = selectedItems
        guard !candidates.isEmpty else {
            return
        }

        isCleaning = true
        errorMessage = nil
        showingCleanupConfirmation = false

        let rule = selectedRule
        cleanupTask = Task {
            let report = await cleaner.clean(rule: rule, items: candidates)
            lastCleanupReport = report
            if report.hasFailures {
                errorMessage = "Some selected items could not be cleaned. Review the cleanup results."
            }
            isCleaning = false
            scan(clearError: false)
        }
    }
}
