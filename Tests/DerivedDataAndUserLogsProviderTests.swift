import Darwin
import Foundation
import Testing
@testable import SpaceMender

struct DerivedDataAndUserLogsProviderTests {
    // MARK: - DerivedData

    @Test
    func derivedDataCleanupIsBlockedWhileXcodeRuns() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let project = root.appending(path: "Project-abcdef", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("stale build".utf8).write(to: project.appending(path: "marker"))

        let rule = derivedDataFixtureRule(location: root)
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: FixedRunningApplications(names: ["Xcode"]),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = ChildDirectoryCleanupProvider(rule: rule, files: files)
        let item = CleanupItem(
            id: project.path,
            providerID: rule.id,
            stableIdentity: project.standardizedFileURL.path,
            displayName: project.lastPathComponent,
            url: project,
            discoveredAt: .now,
            modifiedAt: try FileManager.default.attributesOfItem(atPath: project.path)[.modificationDate] as? Date,
            resourceIdentifier: nil,
            allocatedSize: 1,
            cleanupPolicy: .permanentDelete
        )

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: [item]))

        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(report.outcomes.first?.message?.contains("Xcode") == true)
        #expect(fileManager.fileExists(atPath: project.path))
    }

    @Test
    func derivedDataRuleDocumentsTheBoundedHeuristicAndXcodeBlock() {
        let rule = CleanupRule.xcodeDerivedData
        #expect(rule.safety.consequence.localizedCaseInsensitiveContains("xcode"))
        #expect(rule.defaultRetentionDays == 30)
        #expect(rule.affectedApplicationNames.contains("Xcode"))
    }

    // MARK: - User logs

    @Test(.enabled(if: getuid() != 0))
    func unreadableLogSubdirectoryIsSkippedWithoutAbortingTheWholeScan() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer {
            // Restore permissions before cleanup so the fixture can be removed.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appending(path: "Restricted").path
            )
            try? fileManager.removeItem(at: root)
        }

        let restricted = root.appending(path: "Restricted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: restricted, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: restricted.appending(path: "blocked.log"))

        let readableApp = root.appending(path: "ReadableApp", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: readableApp, withIntermediateDirectories: true)
        let oldLog = readableApp.appending(path: "old.log")
        try Data("old log".utf8).write(to: oldLog)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60 * 86_400)],
            ofItemAtPath: oldLog.path
        )
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)

        let rule = userLogsFixtureRule(location: root)
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = AgeFilteredFilesCleanupProvider(
            rule: rule,
            files: files,
            recursive: true,
            extensions: nil
        )

        let items = try await provider.discover(olderThanDays: 30, now: now)

        #expect(items.map(\.displayName) == ["old.log"])
    }

    @Test
    func nestedLogFileAttributesToItsContainingSubdirectorySafely() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let homebrewDirectory = root.appending(path: "Homebrew", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: homebrewDirectory, withIntermediateDirectories: true)
        let nestedLog = homebrewDirectory.appending(path: "install.log")
        try Data("brew log".utf8).write(to: nestedLog)
        let topLevelLog = root.appending(path: "toplevel.log")
        try Data("top level log".utf8).write(to: topLevelLog)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for file in [nestedLog, topLevelLog] {
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-60 * 86_400)],
                ofItemAtPath: file.path
            )
        }

        let rule = userLogsFixtureRule(location: root)
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = AgeFilteredFilesCleanupProvider(
            rule: rule,
            files: files,
            recursive: true,
            extensions: nil
        )

        let items = try await provider.discover(olderThanDays: 30, now: now)

        let nested = try #require(items.first { $0.displayName == "install.log" })
        let topLevel = try #require(items.first { $0.displayName == "toplevel.log" })
        #expect(nested.originatingApplication == "Homebrew")
        #expect(topLevel.originatingApplication == nil)
    }

    @Test
    func selectedLogIsMovedToTrashRatherThanPermanentlyDeleted() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let log = root.appending(path: "old.log")
        try Data("old log".utf8).write(to: log)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60 * 86_400)],
            ofItemAtPath: log.path
        )

        let rule = userLogsFixtureRule(location: root)
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: .current,
            runningApplicationChecker: NoRunningFixtureApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        let provider = AgeFilteredFilesCleanupProvider(
            rule: rule,
            files: files,
            recursive: true,
            extensions: nil
        )

        let items = try await provider.discover(olderThanDays: 30, now: now)
        #expect(items.map(\.displayName) == ["old.log"])

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: items))

        #expect(report.outcomes.map(\.status) == [.movedToTrash])
        #expect(!fileManager.fileExists(atPath: log.path))
    }

    @Test
    func userLogsRuleDeclaresThirtyDayDefaultRetentionAndTrashConsequence() {
        let rule = CleanupRule.userLogs
        #expect(rule.defaultRetentionDays == 30)
        #expect(rule.cleanupPolicy == .moveToTrash)
        #expect(rule.safety.consequence.localizedCaseInsensitiveContains("trash"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func derivedDataFixtureRule(location: URL) -> CleanupRule {
        CleanupRule(
            id: "xcode-derived-data",
            name: "Xcode DerivedData",
            summary: "Fixture DerivedData",
            locations: [location],
            supportsRetention: true,
            systemImage: "hammer",
            caution: nil,
            affectedApplicationBundleIdentifiers: ["com.apple.dt.Xcode"],
            affectedApplicationNames: ["Xcode"],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .permanentDelete,
                isRegenerable: true,
                requiresPrivilege: false,
                consequence: "Test cleanup"
            ),
            managedLocationDescription: nil,
            cleanupUnavailableReason: nil,
            defaultRetentionDays: 30
        )
    }

    private func userLogsFixtureRule(location: URL) -> CleanupRule {
        CleanupRule(
            id: "user-logs",
            name: "Old user logs",
            summary: "Fixture user logs",
            locations: [location],
            supportsRetention: true,
            systemImage: "doc.text.magnifyingglass",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .moveToTrash,
                isRegenerable: false,
                requiresPrivilege: false,
                consequence: "Test cleanup"
            ),
            managedLocationDescription: nil,
            cleanupUnavailableReason: nil,
            defaultRetentionDays: 30
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
