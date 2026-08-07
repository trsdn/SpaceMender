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

    let rules = CleanupRule.builtIn

    private let scanner = CleanupScanner()
    private let cleaner = CleanupExecutor()
    private var scanTask: Task<Void, Never>?

    init(result: CleanupScanResult? = nil) {
        self.result = result
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
        !selectedItemIDs.isEmpty && !isScanning && !isCleaning
    }

    var allItemsSelected: Bool {
        !items.isEmpty && selectedItemIDs.count == items.count
    }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil

        let rule = selectedRule
        let days = retentionDays
        scanTask = Task {
            do {
                let scanResult = try await scanner.scan(rule: rule, olderThanDays: days)
                guard !Task.isCancelled else {
                    return
                }
                result = scanResult
                selectedItemIDs = []
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                result = nil
                selectedItemIDs = []
                errorMessage = error.localizedDescription
            }
            isScanning = false
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

        do {
            try cleaner.clean(rule: selectedRule, items: candidates)
            isCleaning = false
            scan()
        } catch {
            isCleaning = false
            errorMessage = error.localizedDescription
        }
    }
}
