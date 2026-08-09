import Foundation
import Testing
@testable import SpaceMender

struct BrowserCacheCleanupProviderTests {
    @Test
    func discoversEachProfileAsADistinctPreciseCandidate() async throws {
        let fileManager = FileManager.default
        let chromeRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: chromeRoot) }

        try writeCacheFile(in: chromeRoot, profile: "Default", name: "Cache/entry")
        try writeCacheFile(in: chromeRoot, profile: "Profile 1", name: "Cache/entry")

        let provider = makeProvider(rule: browserFixtureRule(locations: [chromeRoot]))
        let items = try await provider.discover(olderThanDays: 0, now: .now)

        let displayNames = Set(items.map(\.displayName))
        #expect(items.count == 2)
        #expect(displayNames.contains("\(chromeRoot.lastPathComponent) — Default"))
        #expect(displayNames.contains("\(chromeRoot.lastPathComponent) — Profile 1"))
    }

    @Test
    func neverSelectsCookiesHistorySessionsExtensionsOrProfileDataEvenIfPresent() async throws {
        let fileManager = FileManager.default
        let chromeRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: chromeRoot) }

        try writeCacheFile(in: chromeRoot, profile: "Default", name: "Cache/entry")
        // Defense-in-depth fixtures: these must never be selected even
        // though they sit directly under the declared cache root, exactly
        // as real cookies/history/sessions/extensions/profile data never
        // would in a genuine Chrome/Edge installation.
        let sensitiveNames = ["Cookies", "History", "Sessions", "Extensions", "Login Data", "Bookmarks"]
        for name in sensitiveNames {
            let directory = chromeRoot.appending(path: name, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("sensitive".utf8).write(to: directory.appending(path: "data.db"))
        }

        let provider = makeProvider(rule: browserFixtureRule(locations: [chromeRoot]))
        let items = try await provider.discover(olderThanDays: 0, now: .now)

        let displayNames = items.map(\.displayName)
        for name in sensitiveNames {
            #expect(!displayNames.contains { $0.hasSuffix("— \(name)") })
        }
        #expect(displayNames.contains("\(chromeRoot.lastPathComponent) — Default"))
    }

    @Test
    func neverTouchesUnrelatedGoogleDataOutsideTheDeclaredChromeRoot() async throws {
        let fileManager = FileManager.default
        let googleRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: googleRoot) }
        let chromeRoot = googleRoot.appending(path: "Chrome", directoryHint: .isDirectory)
        let unrelatedRoot = googleRoot.appending(path: "OtherGoogleApp", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: chromeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        try writeCacheFile(in: chromeRoot, profile: "Default", name: "Cache/entry")
        try Data("unrelated".utf8).write(to: unrelatedRoot.appending(path: "cache.data"))

        // The rule only ever declares the Chrome subdirectory, never the
        // shared Google parent, so unrelated sibling apps cannot be
        // discovered even by accident.
        let provider = makeProvider(rule: browserFixtureRule(locations: [chromeRoot]))
        let items = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(items.allSatisfy { $0.url?.path.contains("OtherGoogleApp") == false })
        #expect(fileManager.fileExists(atPath: unrelatedRoot.appending(path: "cache.data").path))
    }

    @Test
    func nestedSensitiveNameFailsWholeCandidateClosedInsteadOfPartialDeletion() async throws {
        let fileManager = FileManager.default
        let chromeRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: chromeRoot) }
        let profile = chromeRoot.appending(path: "Default", directoryHint: .isDirectory)
        let nested = profile.appending(path: "Cache", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: nested.appending(path: "entry"))
        // A "Cookies" file nested unexpectedly deep inside the profile
        // cache tree must still block the whole candidate.
        try Data("cookie jar".utf8).write(to: profile.appending(path: "Cookies"))

        let rule = browserFixtureRule(locations: [chromeRoot])
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = BrowserProfileCacheCleanupProvider(rule: rule, files: files)
        let items = try await provider.discover(olderThanDays: 0, now: .now)
        let item = try #require(items.first { $0.displayName.hasSuffix("Default") })

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: [item]))

        #expect(report.outcomes.map(\.status) == [.skippedChanged])
        #expect(fileManager.fileExists(atPath: nested.appending(path: "entry").path))
        #expect(fileManager.fileExists(atPath: profile.appending(path: "Cookies").path))
    }

    @Test
    func cleaningPreservesProfileRootAndDeletesOnlyValidatedContents() async throws {
        let fileManager = FileManager.default
        let chromeRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: chromeRoot) }
        let profile = chromeRoot.appending(path: "Default", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: profile.appending(path: "Cache", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(to: profile.appending(path: "Cache/entry"))
        try fileManager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: profile.path)
        let attributesBefore = try fileManager.attributesOfItem(atPath: profile.path)

        let provider = makeProvider(rule: browserFixtureRule(locations: [chromeRoot]))
        let items = try await provider.discover(olderThanDays: 0, now: .now)
        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

        #expect(report.outcomes.allSatisfy { $0.status == .cleaned })
        #expect(fileManager.fileExists(atPath: profile.path))
        #expect(try fileManager.contentsOfDirectory(atPath: profile.path).isEmpty)
        let attributesAfter = try fileManager.attributesOfItem(atPath: profile.path)
        #expect(
            attributesAfter[.posixPermissions] as? NSNumber
                == attributesBefore[.posixPermissions] as? NSNumber
        )
    }

    @Test
    func runningBrowserHelperProcessVariantBlocksCleanup() async throws {
        let fileManager = FileManager.default
        let chromeRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: chromeRoot) }
        try writeCacheFile(in: chromeRoot, profile: "Default", name: "Cache/entry")

        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: FixedRunningApplications(names: ["Google Chrome Helper (Renderer)"]),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = BrowserProfileCacheCleanupProvider(
            rule: browserFixtureRule(locations: [chromeRoot]),
            files: files
        )
        let items = try await provider.discover(olderThanDays: 0, now: .now)

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

        #expect(report.outcomes.allSatisfy { $0.status == .failed })
        #expect(report.outcomes.first?.message?.contains("Google Chrome Helper (Renderer)") == true)
    }

    @Test
    func browserCachesRuleExplicitlyDescribesWhatItNeverDeletes() {
        let consequence = CleanupRule.browserCaches.safety.consequence
        for keyword in ["cookies", "history", "sessions", "extensions", "profile"] {
            #expect(
                consequence.localizedCaseInsensitiveContains(keyword),
                "Consequence text should mention '\(keyword)' is never deleted"
            )
        }
    }

    private func makeProvider(rule: CleanupRule) -> BrowserProfileCacheCleanupProvider {
        let files = FilesystemProviderSupport(
            fileManager: .default,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        return BrowserProfileCacheCleanupProvider(rule: rule, files: files)
    }

    private func writeCacheFile(in root: URL, profile: String, name: String) throws {
        let fileManager = FileManager.default
        let path = root.appending(path: profile, directoryHint: .isDirectory).appending(path: name)
        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(to: path)
    }

    private func browserFixtureRule(locations: [URL]) -> CleanupRule {
        CleanupRule(
            id: "browser-caches",
            name: "Browser caches",
            summary: "Fixture browser caches",
            locations: locations,
            supportsRetention: false,
            systemImage: "globe",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: ["Google Chrome", "Google Chrome Helper"],
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

private struct FixedRunningApplications: RunningApplicationChecking {
    let names: [String]

    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        self.names
    }
}
