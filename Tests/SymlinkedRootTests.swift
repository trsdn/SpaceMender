import Foundation
import Testing
@testable import SpaceMender

/// Guards issue #2: a declared root that is a symlink is skipped by Foundation, so the category
/// looked empty instead of explaining itself.
///
/// These tests use **real symlinks on the real filesystem** on purpose. The bug exists precisely
/// because `FileManager` refuses to enumerate through a symlinked root — a stubbed file manager
/// would model the behaviour we wish it had and prove nothing.
struct SymlinkedRootTests {
    @Test
    func symlinkedRootIsDetectedWithoutFollowingIt() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        #expect(
            FilesystemProviderSupport.isSymbolicLinkRoot(fixture.linkedRoot),
            "The declared root is a symlink and must be recognised as one"
        )
        #expect(
            !FilesystemProviderSupport.isSymbolicLinkRoot(fixture.realRoot),
            """
            A real directory must not be flagged, even though an ancestor may itself be a \
            symlink (/var → /private/var on macOS). Detection uses lstat semantics.
            """
        )
    }

    @Test
    func symlinkedRootIsReportedRatherThanLookingEmpty() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let rule = fixture.rule(locations: [fixture.linkedRoot])
        let reported = FilesystemProviderSupport.symlinkedRoots(of: rule, fileManager: .default)

        #expect(
            reported.map(\.path) == [fixture.linkedRoot.path],
            """
            The user must be told the location was skipped. Reporting nothing is what made a \
            relocated cache indistinguishable from an empty one.
            """
        )
    }

    @Test
    func realRootsAreNotReported() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let rule = fixture.rule(locations: [fixture.realRoot])

        #expect(
            FilesystemProviderSupport.symlinkedRoots(of: rule, fileManager: .default).isEmpty,
            "A normal root must not produce a warning"
        )
    }

    /// The two scan branches used to disagree: recursive silently yielded `[]` while
    /// non-recursive threw an opaque `NSCocoaErrorDomain 256`. Both must now simply skip.
    @Test
    func bothScanBranchesSkipSymlinkedRootsWithoutThrowing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let support = makeSupport()
        let rule = fixture.rule(locations: [fixture.linkedRoot])

        for recursive in [true, false] {
            let items = try support.scanFiles(
                rule: rule,
                recursive: recursive,
                extensions: nil,
                olderThanDays: 0,
                now: .now
            )
            #expect(
                items.isEmpty,
                "recursive=\(recursive) must yield nothing for a symlinked root, not throw"
            )
        }
    }

    /// Found by driving the live app, not by the unit tests: `scanFiles` is only one of four scan
    /// entry points. Fixing it alone still left Xcode DerivedData showing "Scan failed", because
    /// that category uses `scanChildDirectories`. Every entry point must behave the same way.
    @Test
    func everyScanEntryPointSkipsSymlinkedRootsWithoutThrowing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let support = makeSupport()
        let rule = fixture.rule(locations: [fixture.linkedRoot])

        #expect(
            try support.scanChildDirectories(rule: rule, olderThanDays: 0, now: .now).isEmpty,
            "scanChildDirectories backs Xcode DerivedData and simulators"
        )
        #expect(
            try support.scanCacheRootChildren(rule: rule, excludedNames: [], now: .now).isEmpty,
            "scanCacheRootChildren backs browser caches"
        )
        #expect(
            try support.scanFixedRoots(rule: rule, now: .now).isEmpty,
            "scanFixedRoots already skipped, but silently — it must stay consistent"
        )
    }

    /// Containment guard: skipping must not become "resolve the link and scan the target".
    @Test
    func contentsBehindTheSymlinkAreNeverDiscovered() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let support = makeSupport()
        let items = try support.scanFiles(
            rule: fixture.rule(locations: [fixture.linkedRoot]),
            recursive: true,
            extensions: nil,
            olderThanDays: 0,
            now: .now
        )

        #expect(
            !items.contains { $0.url?.lastPathComponent == "payload.log" },
            """
            Following the link would widen the fixed-canonical-root containment guarantee. \
            The file behind the link must stay invisible to cleanup.
            """
        )
    }

    /// A real directory must still be scanned normally — the guard must not skip everything.
    @Test
    func realRootsAreStillScanned() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let items = try makeSupport().scanFiles(
            rule: fixture.rule(locations: [fixture.realRoot]),
            recursive: true,
            extensions: nil,
            olderThanDays: 0,
            now: .now
        )

        #expect(
            items.contains { $0.url?.lastPathComponent == "ordinary.log" },
            "Skipping symlinks must not suppress ordinary roots"
        )
    }

    // MARK: - Fixture

    private func makeSupport() -> FilesystemProviderSupport {
        FilesystemProviderSupport(
            fileManager: .default,
            calendar: .current,
            runningApplicationChecker: NoRunningApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
    }

    private struct Fixture {
        let base: URL
        let realRoot: URL
        let linkedRoot: URL

        func rule(locations: [URL]) -> CleanupRule {
            let template = CleanupRule.userLogs
            return CleanupRule(
                id: template.id,
                name: template.name,
                summary: template.summary,
                locations: locations,
                supportsRetention: template.supportsRetention,
                systemImage: template.systemImage,
                caution: template.caution,
                affectedApplicationBundleIdentifiers: template.affectedApplicationBundleIdentifiers,
                affectedApplicationNames: template.affectedApplicationNames,
                safety: template.safety,
                managedLocationDescription: template.managedLocationDescription,
                cleanupUnavailableReason: template.cleanupUnavailableReason,
                defaultRetentionDays: template.defaultRetentionDays
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let target = base.appending(path: "relocated", directoryHint: .isDirectory)
        let realRoot = base.appending(path: "ordinary", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: target.appending(path: "payload.log"))
        try Data("payload".utf8).write(to: realRoot.appending(path: "ordinary.log"))

        let linkedRoot = base.appending(path: "Logs", directoryHint: .notDirectory)
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: target)

        return Fixture(base: base, realRoot: realRoot, linkedRoot: linkedRoot)
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
