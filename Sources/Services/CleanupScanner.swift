import Foundation

protocol CleanupScanning: Sendable {
    func scan(rule: CleanupRule, olderThanDays days: Int, now: Date) async throws -> CleanupScanResult
}

extension CleanupScanning {
    func scan(rule: CleanupRule, olderThanDays days: Int) async throws -> CleanupScanResult {
        try await scan(rule: rule, olderThanDays: days, now: .now)
    }
}

actor CleanupScanner: CleanupScanning {
    private let catalog: CleanupProviderCatalog

    init(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        commandRunner: any CommandRunning = CommandRunner()
    ) {
        catalog = .builtIn(
            fileManager: fileManager,
            calendar: calendar,
            commandRunner: commandRunner
        )
    }

    init(catalog: CleanupProviderCatalog) {
        self.catalog = catalog
    }

    func scan(
        rule: CleanupRule,
        olderThanDays days: Int,
        now: Date
    ) async throws -> CleanupScanResult {
        guard let provider = catalog.provider(id: rule.id) else {
            throw CleanupProviderError.providerNotRegistered(rule.id)
        }
        return try await provider.scan(olderThanDays: days, now: now)
    }
}
