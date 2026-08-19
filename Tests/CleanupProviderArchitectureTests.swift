import Foundation
import Testing
@testable import SpaceMender

struct CleanupProviderArchitectureTests {
    @Test
    func registeringProviderNeedsOnlyProviderAndCatalogEntry() async throws {
        let provider = FixtureProvider()
        let catalog = CleanupProviderCatalog(providers: [provider])
        let scanner = CleanupScanner(catalog: catalog)
        let executor = CleanupExecutor(catalog: catalog)

        #expect(catalog.rules.map(\.id) == ["fixture-provider"])
        #expect(provider.previewMetadata.id == provider.rule.id)
        #expect(provider.safetyMetadata.cleanupPolicy == .externalCommand)
        #expect(provider.availability == .available)
        #expect(provider.runningApplicationBehavior.processNames.isEmpty)
        let result = try await scanner.scan(
            rule: provider.rule,
            olderThanDays: 0,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        #expect(result.items.map(\.id) == ["fixture-item"])

        let report = await executor.clean(rule: provider.rule, items: result.items)
        #expect(report.outcomes.map(\.status) == [.cleaned])
    }

    @Test
    func unregisteredProviderFailsWithoutScannerOrExecutorSwitches() async {
        let rule = FixtureProvider().rule
        let scanner = CleanupScanner(catalog: CleanupProviderCatalog(providers: []))

        do {
            _ = try await scanner.scan(rule: rule, olderThanDays: 0)
            Issue.record("Expected an unregistered-provider error")
        } catch let error as CleanupProviderError {
            guard case .providerNotRegistered("fixture-provider") = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func externalCommandFailureDoesNotReportCleanedItems() async throws {
        let rule = FixtureProvider().rule
        let provider = ExternalCommandCleanupProvider(
            rule: rule,
            fileManager: .default,
            commandRunner: PreviewThenFailCommandRunner(),
            runningApplicationChecker: NoRunningFixtureApplications(),
            executableCandidates: [URL(filePath: "/usr/bin/true")],
            previewArguments: [],
            executionArguments: [],
            previewParser: { _ in .known(bytes: 1) }
        )
        let item = try #require(
            try await provider.discover(olderThanDays: 0, now: Date.now).first
        )

        let report = await provider.execute(
            plan: await provider.makeExecutionPlan(items: [item])
        )

        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(
            report.outcomes.first?.message?.contains("rescan") == true,
            "A failed outcome must carry recovery guidance; the exact wording is not the contract"
        )
        #expect(report.outcomes.first?.technicalDetails == "command failed")
    }

    /// Guards the production wiring, not a hand-assembled one. `AppViewModel`
    /// must build every service from a single catalog: providers such as the
    /// npm cache provider record discovery in instance state and validate
    /// against it, so an executor holding a *different* provider instance
    /// fails to clean items the scanner legitimately found. Injecting a
    /// shared catalog into a scanner and an executor by hand — as the tests
    /// above do — cannot catch that regression, because it is exactly the
    /// wiring production would no longer have.
    @Test
    @MainActor
    func viewModelBuildsEveryServiceFromOneCatalog() async {
        let provider = StatefulFixtureProvider()
        let viewModel = AppViewModel(
            catalog: CleanupProviderCatalog(providers: [provider])
        )

        // The overview scanner was built from the injected catalog.
        #expect(viewModel.rules.map(\.id) == ["stateful-fixture-provider"])

        viewModel.selectedRule = provider.rule
        viewModel.scan()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.items.map(\.id) == ["stateful-item"])

        viewModel.selectAll()
        viewModel.performCleanup()
        try? await Task.sleep(for: .milliseconds(300))

        // .cleaned only if the executing provider is the very same instance
        // that recorded discovery during the scan.
        #expect(viewModel.lastCleanupReport?.outcomes.map(\.status) == [.cleaned])
        #expect(viewModel.lastCleanupReport?.outcomes.first?.message != "never discovered")
    }
}

/// Fails execution unless `discover` ran on this same instance, making a
/// scanner/executor instance split observable instead of silent.
private final class StatefulFixtureProvider: CleanupProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var didDiscover = false

    let rule = CleanupRule(
        id: "stateful-fixture-provider",
        name: "Stateful fixture",
        summary: "Records discovery in instance state",
        locations: [],
        supportsRetention: false,
        systemImage: "testtube.2",
        caution: nil,
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .externalCommand,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Test cleanup"
        ),
        managedLocationDescription: "Fixture-managed",
        cleanupUnavailableReason: nil
    )

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        lock.withLock { didDiscover = true }
        return [
            CleanupItem(
                id: "stateful-item",
                providerID: rule.id,
                stableIdentity: "stateful-item",
                displayName: "Stateful item",
                url: nil,
                discoveredAt: now,
                modifiedAt: nil,
                resourceIdentifier: nil,
                allocatedSize: 1,
                cleanupPolicy: rule.cleanupPolicy
            )
        ]
    }

    func validate(_ item: CleanupItem) async throws {
        guard lock.withLock({ didDiscover }) else {
            throw CleanupValidationError.unsafePath
        }
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        let discovered = lock.withLock { didDiscover }
        return CleanupReport(
            outcomes: plan.items.map {
                CleanupItemOutcome(
                    itemID: $0.id,
                    displayName: $0.displayName,
                    status: discovered ? .cleaned : .failed,
                    message: discovered ? nil : "never discovered"
                )
            }
        )
    }
}

private struct FixtureProvider: CleanupProvider {
    let rule = CleanupRule(
        id: "fixture-provider",
        name: "Fixture",
        summary: "Architecture fixture",
        locations: [],
        supportsRetention: false,
        systemImage: "testtube.2",
        caution: nil,
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .externalCommand,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Test cleanup"
        ),
        managedLocationDescription: "Fixture-managed",
        cleanupUnavailableReason: nil
    )

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        [
            CleanupItem(
                id: "fixture-item",
                providerID: rule.id,
                stableIdentity: "fixture-item",
                displayName: "Fixture item",
                url: nil,
                discoveredAt: now,
                modifiedAt: nil,
                resourceIdentifier: nil,
                allocatedSize: 1,
                cleanupPolicy: rule.cleanupPolicy
            )
        ]
    }

    func validate(_ item: CleanupItem) async throws {
        guard item.providerID == rule.id else {
            throw CleanupValidationError.providerMismatch
        }
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        CleanupReport(
            outcomes: plan.items.map {
                CleanupItemOutcome(
                    itemID: $0.id,
                    displayName: $0.displayName,
                    status: .cleaned,
                    message: nil
                )
            }
        )
    }
}

private final class PreviewThenFailCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let invocation = lock.withLock {
            invocationCount += 1
            return invocationCount
        }
        if invocation == 1 {
            return CommandResult(
                standardOutput: Data("1MB".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: Data(),
            standardError: Data("command failed".utf8),
            terminationStatus: 42
        )
    }
}

private struct NoRunningFixtureApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}
