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

private struct NoRunningFixtureApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}
