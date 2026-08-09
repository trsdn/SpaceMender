import Foundation
import Testing
@testable import SpaceMender

struct NpmCacheDiscoveryTests {
    @Test
    func discoversUniqueCacheRootsAcrossMultipleNpmInstallations() async throws {
        let fileManager = FileManager.default
        let scriptsRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: scriptsRoot) }
        let sharedCacheRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: sharedCacheRoot) }

        // Two different "npm" installations (for example Homebrew and nvm)
        // that happen to report the exact same configured cache directory
        // must be deduplicated into a single discovered root.
        let homebrewNpm = try makeFakeNpm(
            named: "homebrew-npm",
            in: scriptsRoot,
            reportsCache: sharedCacheRoot.path
        )
        let nvmNpm = try makeFakeNpm(
            named: "nvm-npm",
            in: scriptsRoot,
            reportsCache: sharedCacheRoot.path
        )

        let discoverer = NpmEnvironmentCacheRootDiscoverer(
            candidateExecutables: [homebrewNpm, nvmNpm],
            commandRunner: CommandRunner()
        )

        let roots = await discoverer.discoverCacheRoots()

        #expect(roots.map(\.standardizedFileURL.path) == [sharedCacheRoot.standardizedFileURL.path])
    }

    @Test
    func skipsMissingAndNonExecutableCandidates() async throws {
        let missing = URL(filePath: "/tmp/definitely-not-installed-npm-\(UUID().uuidString)")

        let discoverer = NpmEnvironmentCacheRootDiscoverer(
            candidateExecutables: [missing],
            commandRunner: CommandRunner()
        )

        let roots = await discoverer.discoverCacheRoots()

        #expect(roots.isEmpty)
    }

    @Test
    func rejectsSuspiciouslyBroadReportedCacheRoots() async throws {
        let fileManager = FileManager.default
        let scriptsRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: scriptsRoot) }
        let rootReportingNpm = try makeFakeNpm(named: "root-npm", in: scriptsRoot, reportsCache: "/")
        let homeReportingNpm = try makeFakeNpm(
            named: "home-npm",
            in: scriptsRoot,
            reportsCache: fileManager.homeDirectoryForCurrentUser.path
        )

        let discoverer = NpmEnvironmentCacheRootDiscoverer(
            candidateExecutables: [rootReportingNpm, homeReportingNpm],
            commandRunner: CommandRunner()
        )

        let roots = await discoverer.discoverCacheRoots()

        #expect(roots.isEmpty)
    }

    @Test
    func providerPreservesEachDiscoveredRootAndDeletesOnlyValidatedContents() async throws {
        let fileManager = FileManager.default
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let cacacheDir = cacheRoot.appending(path: "_cacache", directoryHint: .isDirectory)
        let npxDir = cacheRoot.appending(path: "_npx", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: cacacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: npxDir, withIntermediateDirectories: true)
        try Data("cached package".utf8).write(to: cacacheDir.appending(path: "entry.bin"))
        try Data("npx install".utf8).write(to: npxDir.appending(path: "package.json"))

        let fallbackRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: fallbackRoot) }
        let rule = npmFixtureRule(fallbackLocations: [fallbackRoot])
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = NpmCacheCleanupProvider(
            rule: rule,
            files: files,
            discoverer: FixedRootsDiscoverer(roots: [cacheRoot])
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)
        #expect(items.map(\.displayName).sorted() == ["_cacache", "_npx"])

        let attributesBefore = try fileManager.attributesOfItem(atPath: cacacheDir.path)
        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

        #expect(report.outcomes.allSatisfy { $0.status == .cleaned })
        #expect(fileManager.fileExists(atPath: cacacheDir.path))
        #expect(fileManager.fileExists(atPath: npxDir.path))
        #expect(try fileManager.contentsOfDirectory(atPath: cacacheDir.path).isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: npxDir.path).isEmpty)
        let attributesAfter = try fileManager.attributesOfItem(atPath: cacacheDir.path)
        #expect(
            attributesAfter[.posixPermissions] as? NSNumber
                == attributesBefore[.posixPermissions] as? NSNumber
        )
    }

    @Test
    func laterOverlappingDiscoverNeverInvalidatesItemsFromAnEarlierScan() async throws {
        let fileManager = FileManager.default
        let firstCacheRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: firstCacheRoot) }
        let secondCacheRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: secondCacheRoot) }

        for root in [firstCacheRoot, secondCacheRoot] {
            let cacacheDir = root.appending(path: "_cacache", directoryHint: .isDirectory)
            let npxDir = root.appending(path: "_npx", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: cacacheDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: npxDir, withIntermediateDirectories: true)
            try Data("cached package".utf8).write(to: cacacheDir.appending(path: "entry.bin"))
            try Data("npx install".utf8).write(to: npxDir.appending(path: "package.json"))
        }

        let fallbackRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: fallbackRoot) }
        let rule = npmFixtureRule(fallbackLocations: [fallbackRoot])
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = NpmCacheCleanupProvider(
            rule: rule,
            files: files,
            discoverer: SequentialRootsDiscoverer(rootsPerCall: [[firstCacheRoot], [secondCacheRoot]])
        )

        // First scan discovers `firstCacheRoot`'s children and hands the
        // resulting items back to a caller that has not yet validated or
        // executed a cleanup plan for them.
        let firstScanItems = try await provider.discover(olderThanDays: 0, now: .now)
        #expect(firstScanItems.map(\.displayName).sorted() == ["_cacache", "_npx"])

        // A second, overlapping/later scan (for example a background
        // rescan racing an in-flight cleanup, or the user hitting refresh
        // again) discovers a completely different root before the first
        // scan's items have been validated or cleaned.
        let secondScanItems = try await provider.discover(olderThanDays: 0, now: .now)
        #expect(secondScanItems.map(\.displayName).sorted() == ["_cacache", "_npx"])

        // The display-facing `rule` still reflects only the most recent
        // scan (unchanged, existing behavior) — it is validate/execute
        // that must no longer depend on it.
        let currentLocations = Set(provider.rule.locations.map(\.standardizedFileURL.path))
        #expect(
            currentLocations.contains(
                secondCacheRoot.appending(path: "_cacache", directoryHint: .isDirectory)
                    .standardizedFileURL.path
            )
        )
        #expect(
            !currentLocations.contains(
                firstCacheRoot.appending(path: "_cacache", directoryHint: .isDirectory)
                    .standardizedFileURL.path
            )
        )

        // Executing the FIRST scan's now-stale items after the second,
        // overlapping scan ran must still succeed: the first scan's roots
        // must not have been overwritten/evicted by the later discovery.
        let firstPlan = await provider.makeExecutionPlan(items: firstScanItems)
        let firstReport = await provider.execute(plan: firstPlan)

        #expect(firstReport.outcomes.allSatisfy { $0.status == .cleaned })
        let firstCacacheDir = firstCacheRoot.appending(path: "_cacache", directoryHint: .isDirectory)
        let firstNpxDir = firstCacheRoot.appending(path: "_npx", directoryHint: .isDirectory)
        #expect(fileManager.fileExists(atPath: firstCacacheDir.path))
        #expect(fileManager.fileExists(atPath: firstNpxDir.path))
        #expect(try fileManager.contentsOfDirectory(atPath: firstCacacheDir.path).isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: firstNpxDir.path).isEmpty)

        // The second scan's own items must remain independently valid too.
        let secondPlan = await provider.makeExecutionPlan(items: secondScanItems)
        let secondReport = await provider.execute(plan: secondPlan)
        #expect(secondReport.outcomes.allSatisfy { $0.status == .cleaned })
        let secondCacacheDir = secondCacheRoot.appending(path: "_cacache", directoryHint: .isDirectory)
        #expect(try fileManager.contentsOfDirectory(atPath: secondCacacheDir.path).isEmpty)
    }

    @Test
    func providerFallsBackToDeclaredDefaultsWhenDiscoveryFindsNothing() async throws {
        let fileManager = FileManager.default
        let fallbackRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: fallbackRoot) }
        try Data("fallback cache".utf8).write(to: fallbackRoot.appending(path: "entry.bin"))

        let rule = npmFixtureRule(fallbackLocations: [fallbackRoot])
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = NpmCacheCleanupProvider(
            rule: rule,
            files: files,
            discoverer: FixedRootsDiscoverer(roots: [])
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(items.map(\.displayName) == [fallbackRoot.lastPathComponent])
    }

    @Test
    func npmCachesRuleDeclaresDistinctConsequenceTextAndNoRetentionControl() {
        #expect(!CleanupRule.npmCaches.supportsRetention)
        #expect(CleanupRule.npmCaches.defaultRetentionDays == nil)
        #expect(CleanupRule.npmCaches.safety.consequence.localizedCaseInsensitiveContains("npm") == true)
    }

    private func npmFixtureRule(fallbackLocations: [URL]) -> CleanupRule {
        CleanupRule(
            id: "npm-caches",
            name: "npm caches",
            summary: "Fixture npm caches",
            locations: fallbackLocations,
            supportsRetention: false,
            systemImage: "shippingbox",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .permanentDeleteContents,
                isRegenerable: true,
                requiresPrivilege: false,
                consequence: "Test cleanup"
            ),
            managedLocationDescription: nil,
            cleanupUnavailableReason: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakeNpm(named name: String, in directory: URL, reportsCache cachePath: String) throws -> URL {
        let script = directory.appending(path: name)
        let contents = """
        #!/bin/sh
        if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "cache" ]; then
          echo "\(cachePath)"
          exit 0
        fi
        exit 1
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private struct FixedRootsDiscoverer: NpmCacheRootDiscovering {
    let roots: [URL]

    func discoverCacheRoots() async -> [URL] {
        roots
    }
}

/// Returns a different, fixed set of roots on each successive call (the
/// last set is repeated once exhausted), for exercising an overlapping or
/// repeated scan that discovers roots different from an earlier call.
private final class SequentialRootsDiscoverer: NpmCacheRootDiscovering, @unchecked Sendable {
    private let rootsPerCall: [[URL]]
    private let lock = NSLock()
    private var callIndex = 0

    init(rootsPerCall: [[URL]]) {
        self.rootsPerCall = rootsPerCall
    }

    func discoverCacheRoots() async -> [URL] {
        lock.withLock {
            defer { callIndex += 1 }
            guard callIndex < rootsPerCall.count else {
                return rootsPerCall.last ?? []
            }
            return rootsPerCall[callIndex]
        }
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
