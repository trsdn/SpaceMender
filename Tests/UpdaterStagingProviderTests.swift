import Foundation
import Testing
@testable import SpaceMender

/// Covers the `app-updater-staging` provider.
///
/// This provider is unusual, and the tests exist because of it: its declared root is
/// `~/Library/Caches`, which holds everything the user has ever cached. Every other filesystem
/// rule points at a narrow directory it fully owns, so "an immediate child of the root" is a
/// safe licence to delete. Here it emphatically is not — only the naming convention makes a
/// child a candidate, so that convention has to hold during **validation**, not just discovery.
struct UpdaterStagingProviderTests {
    @Test
    func discoversOnlyRecognisedStagingFolders() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanUp() }

        let items = try await fixture.provider.discover(olderThanDays: 0, now: .now)
        let discovered = Set(fixture.names(of: items))

        #expect(
            discovered == ["com.example.App.ShipIt", "example-updater"],
            """
            Only the two updater staging conventions may be offered. Anything else under \
            ~/Library/Caches belongs to an unrelated app and is not this rule's business.
            """
        )
    }

    @Test
    func unrelatedCacheDirectoriesAreNeverOffered() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanUp() }

        let items = try await fixture.provider.discover(olderThanDays: 0, now: .now)
        let names = fixture.names(of: items)

        #expect(!names.contains("com.apple.Safari"))
        #expect(!names.contains("SomeImportantCache"))
    }

    /// The important one: discovery is not the security boundary.
    @Test
    func validationRejectsAChildThatDoesNotMatchTheConvention() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanUp() }

        let smuggled = try fixture.item(for: "com.apple.Safari")

        await #expect(throws: CleanupValidationError.self) {
            try await fixture.provider.validate(smuggled)
        }
    }

    @Test
    func validationAcceptsARealStagingFolder() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanUp() }

        let staging = try fixture.item(for: "com.example.App.ShipIt")

        try await fixture.provider.validate(staging)
    }

    /// A staging folder is Trash-recoverable on purpose: this category is newer and less proven
    /// than the caches that are deleted outright.
    @Test
    func stagingFoldersGoToTrashRatherThanBeingDeletedOutright() {
        #expect(CleanupRule.appUpdaterStaging.cleanupPolicy == .moveToTrash)
    }

    @Test
    func suffixMatchingIsCaseInsensitive() async throws {
        let fixture = try CacheFixture(extraDirectories: ["com.example.Other.shipit"])
        defer { fixture.cleanUp() }

        let items = try await fixture.provider.discover(olderThanDays: 0, now: .now)
        let names = fixture.names(of: items)

        #expect(
            names.contains("com.example.Other.shipit"),
            "Squirrel's casing is not guaranteed, so matching must not depend on it"
        )
    }
}

private struct CacheFixture {
    let base: URL
    let root: URL
    let provider: UpdaterStagingCleanupProvider
    private let rule: CleanupRule
    private let files: FilesystemProviderSupport

    init(extraDirectories: [String] = []) throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "updater-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "Caches", directoryHint: .isDirectory)

        let names = [
            "com.example.App.ShipIt",
            "example-updater",
            "com.apple.Safari",
            "SomeImportantCache"
        ] + extraDirectories
        for name in names {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // Non-empty, because a zero-byte candidate is filtered out of discovery.
            try Data(repeating: 0x7F, count: 4096)
                .write(to: directory.appending(path: "payload.bin"))
        }

        rule = CleanupRule(
            id: CleanupRule.appUpdaterStaging.id,
            name: CleanupRule.appUpdaterStaging.name,
            summary: CleanupRule.appUpdaterStaging.summary,
            locations: [root],
            supportsRetention: false,
            systemImage: CleanupRule.appUpdaterStaging.systemImage,
            caution: CleanupRule.appUpdaterStaging.caution,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupRule.appUpdaterStaging.safety,
            managedLocationDescription: nil,
            cleanupUnavailableReason: nil
        )
        files = FilesystemProviderSupport(
            fileManager: .default,
            calendar: .current,
            runningApplicationChecker: NoRunningApplications(),
            fileTrasher: RefusingFileTrasher()
        )
        provider = UpdaterStagingCleanupProvider(rule: rule, files: files)
    }

    func names(of items: [CleanupItem]) -> [String] {
        items.compactMap { $0.url?.lastPathComponent }
    }

    /// Builds an item pointing at `name` the way discovery would, so validation is tested
    /// against a well-formed item and can only reject it on the naming rule.
    func item(for name: String) throws -> CleanupItem {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return CleanupItem(
            id: url.path,
            providerID: rule.id,
            stableIdentity: url.standardizedFileURL.path,
            displayName: name,
            url: url,
            discoveredAt: .now,
            modifiedAt: values.contentModificationDate,
            resourceIdentifier: FilesystemProviderSupport.resourceIdentifier(
                for: url,
                fileManager: .default
            ),
            allocatedSize: 4096,
            cleanupPolicy: rule.cleanupPolicy
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}

private struct NoRunningApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}

/// Deleting is never exercised here; a trasher that refuses makes an accidental deletion in a
/// future edit of these tests fail loudly instead of quietly removing a fixture.
private struct RefusingFileTrasher: FileTrashing {
    func trashItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
