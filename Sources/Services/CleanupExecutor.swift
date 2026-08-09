import AppKit
import Foundation

protocol RunningApplicationChecking: Sendable {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String]
}

struct RunningApplicationChecker: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            let bundleMatches = application.bundleIdentifier.map(bundleIdentifiers.contains) ?? false
            let nameMatches = application.localizedName.map { applicationName in
                names.contains { configuredName in
                    applicationName == configuredName
                        || applicationName.hasPrefix(configuredName + " ")
                }
            } ?? false
            return bundleMatches || nameMatches ? application.localizedName : nil
        }
    }
}

protocol FileTrashing: Sendable {
    func trashItem(at url: URL) throws
}

struct WorkspaceFileTrasher: FileTrashing {
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

protocol CleanupExecuting: Sendable {
    func clean(rule: CleanupRule, items: [CleanupItem]) async -> CleanupReport
}

actor CleanupExecutor: CleanupExecuting {
    private let catalog: CleanupProviderCatalog

    init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = CommandRunner(),
        runningApplicationChecker: any RunningApplicationChecking = RunningApplicationChecker(),
        fileTrasher: any FileTrashing = WorkspaceFileTrasher()
    ) {
        catalog = .builtIn(
            fileManager: fileManager,
            commandRunner: commandRunner,
            runningApplicationChecker: runningApplicationChecker,
            fileTrasher: fileTrasher
        )
    }

    init(catalog: CleanupProviderCatalog) {
        self.catalog = catalog
    }

    func clean(rule: CleanupRule, items: [CleanupItem]) async -> CleanupReport {
        guard !items.isEmpty else {
            return CleanupReport(outcomes: [])
        }
        guard let provider = catalog.provider(id: rule.id) else {
            return CleanupReport(
                outcomes: items.map {
                    CleanupItemOutcome(
                        itemID: $0.id,
                        displayName: $0.displayName,
                        status: .failed,
                        message: CleanupProviderError.providerNotRegistered(rule.id).localizedDescription
                    )
                }
            )
        }
        let plan = await provider.makeExecutionPlan(items: items)
        return await provider.execute(plan: plan)
    }
}
