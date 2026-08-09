import Foundation
import Testing
@testable import SpaceMender

struct DeveloperCacheCleanupProviderTests {
    @Test
    func builtInDeveloperCachesDiscoverHiddenRootsAndPreserveRootsAfterCleanup() async throws {
        let builtInRules = [
            CleanupRule.swiftPMCache,
            CleanupRule.playwrightCache,
            CleanupRule.copilotCache
        ]

        for builtInRule in builtInRules {
            let roots = try makeTemporaryRoots(count: max(1, builtInRule.locations.count))
            do {
                defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
                for root in roots {
                    try Data("hidden cache".utf8).write(to: root.appending(path: ".cache.data"))
                }

                let provider = makeProvider(rule: fixtureRule(from: builtInRule, locations: roots))
                let items = try await provider.discover(olderThanDays: 0, now: .now)
                let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

                #expect(
                    items.count == roots.count,
                    "\(builtInRule.id) should discover each declared fixed cache root"
                )
                #expect(
                    items.allSatisfy { $0.allocatedSize > 0 },
                    "\(builtInRule.id) should count hidden-only cache contents"
                )
                #expect(
                    report.outcomes.allSatisfy { $0.status == .cleaned },
                    "\(builtInRule.id) cleanup should succeed for isolated roots"
                )
                for root in roots {
                    #expect(
                        FileManager.default.fileExists(atPath: root.path),
                        "\(builtInRule.id) should preserve root \(root.lastPathComponent)"
                    )
                    #expect(
                        try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                        "\(builtInRule.id) should delete only the root's contents"
                    )
                }
            }
        }
    }

    @Test
    func copilotCleanupCleansOnlyTheSelectedDeclaredRoot() async throws {
        let roots = try makeTemporaryRoots(count: CleanupRule.copilotCache.locations.count)
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }

        let selectedRoot = roots[0]
        let unselectedRoot = roots[1]
        try Data("selected".utf8).write(to: selectedRoot.appending(path: "selected.cache"))
        try Data("unselected".utf8).write(to: unselectedRoot.appending(path: "unselected.cache"))

        let provider = makeProvider(rule: fixtureRule(from: CleanupRule.copilotCache, locations: roots))
        let items = try await provider.discover(olderThanDays: 0, now: .now)
        let selectedItem = try #require(items.first { $0.url?.path == selectedRoot.path })

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: [selectedItem]))

        #expect(report.outcomes.map(\.status) == [.cleaned])
        #expect(try FileManager.default.contentsOfDirectory(atPath: selectedRoot.path).isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: unselectedRoot.appending(path: "unselected.cache").path
            )
        )
    }

    @Test
    func builtInDeveloperCachesBlockCleanupWhileAffectedToolIsRunning() async throws {
        let cases: [(CleanupRule, String)] = [
            (.swiftPMCache, "Xcode"),
            (.playwrightCache, "playwright"),
            (.copilotCache, "copilot")
        ]

        for (builtInRule, runningName) in cases {
            let root = try makeTemporaryRoot()
            do {
                defer { try? FileManager.default.removeItem(at: root) }
                try Data("cache".utf8).write(to: root.appending(path: "entry.cache"))

                let provider = makeProvider(
                    rule: fixtureRule(from: builtInRule, locations: [root]),
                    runningApplications: FixedRunningDeveloperApplications(names: [runningName])
                )
                let items = try await provider.discover(olderThanDays: 0, now: .now)

                let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

                #expect(
                    report.outcomes.allSatisfy { $0.status == .failed },
                    "\(builtInRule.id) should fail closed while \(runningName) is active"
                )
                #expect(report.outcomes.first?.message?.contains(runningName) == true)
                #expect(FileManager.default.fileExists(atPath: root.appending(path: "entry.cache").path))
            }
        }
    }

    private func makeProvider(
        rule: CleanupRule,
        runningApplications: any RunningApplicationChecking = NoRunningDeveloperApplications()
    ) -> FixedCacheRootsCleanupProvider {
        let files = FilesystemProviderSupport(
            fileManager: .default,
            calendar: .current,
            runningApplicationChecker: runningApplications,
            fileTrasher: WorkspaceFileTrasher()
        )
        return FixedCacheRootsCleanupProvider(rule: rule, files: files)
    }

    private func fixtureRule(from builtInRule: CleanupRule, locations: [URL]) -> CleanupRule {
        CleanupRule(
            id: builtInRule.id,
            name: builtInRule.name,
            summary: builtInRule.summary,
            locations: locations,
            supportsRetention: builtInRule.supportsRetention,
            systemImage: builtInRule.systemImage,
            caution: builtInRule.caution,
            affectedApplicationBundleIdentifiers: builtInRule.affectedApplicationBundleIdentifiers,
            affectedApplicationNames: builtInRule.affectedApplicationNames,
            safety: builtInRule.safety,
            managedLocationDescription: builtInRule.managedLocationDescription,
            cleanupUnavailableReason: builtInRule.cleanupUnavailableReason,
            defaultRetentionDays: builtInRule.defaultRetentionDays
        )
    }

    private func makeTemporaryRoots(count: Int) throws -> [URL] {
        try (0..<count).map { _ in
            try makeTemporaryRoot()
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct NoRunningDeveloperApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}

private struct FixedRunningDeveloperApplications: RunningApplicationChecking {
    let names: [String]

    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        self.names
    }
}
