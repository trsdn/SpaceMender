import Foundation
import Testing
@testable import SpaceMender

struct DefenderPrivilegedProviderTests {
    @Test
    func missingHelperKeepsDefenderExplicitlyScanOnly() async throws {
        let fixture = try ProviderFixture(helperAvailability: .notInstalled)
        defer { fixture.removeRoot() }

        let result = try await fixture.provider.scan(
            olderThanDays: 30,
            now: fixture.now
        )

        #expect(result.items.count == 1)
        #expect(result.rule.cleanupUnavailableReason?.contains("scan-only") == true)
    }

    @Test
    func readyHelperReceivesOnlyExactCandidateIdentity() async throws {
        let fixture = try ProviderFixture(helperAvailability: .ready)
        defer { fixture.removeRoot() }
        let items = try await fixture.provider.discover(olderThanDays: 30, now: fixture.now)

        let report = await fixture.provider.execute(
            plan: await fixture.provider.makeExecutionPlan(items: items)
        )

        #expect(report.outcomes.map(\.status) == [.cleaned])
        let requests = fixture.helper.requests
        #expect(requests.count == 1)
        #expect(requests.first?.fileName == "selected.zip")
        #expect(requests.first?.resourceIdentifier == items.first?.resourceIdentifier)
    }

    @Test
    func unauthenticatedHelperDisablesCleanup() async throws {
        let fixture = try ProviderFixture(helperAvailability: .unauthenticated)
        defer { fixture.removeRoot() }
        let items = try await fixture.provider.discover(olderThanDays: 30, now: fixture.now)

        let report = await fixture.provider.execute(
            plan: await fixture.provider.makeExecutionPlan(items: items)
        )

        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(fixture.helper.requests.isEmpty)
    }
}

private final class RecordingDefenderHelper: DefenderPrivilegedHelperServing, @unchecked Sendable {
    private let lock = NSLock()
    let availability: DefenderHelperAvailability
    private var requestStorage: [DefenderCandidateIdentity] = []

    init(availability: DefenderHelperAvailability) {
        self.availability = availability
    }

    var cachedAvailability: DefenderHelperAvailability {
        availability
    }

    var requests: [DefenderCandidateIdentity] {
        lock.withLock { requestStorage }
    }

    func refreshAvailability() async -> DefenderHelperAvailability {
        availability
    }

    func remove(
        candidates: [DefenderCandidateIdentity]
    ) async throws -> [DefenderHelperItemOutcome] {
        lock.withLock {
            requestStorage.append(contentsOf: candidates)
        }
        return candidates.map {
            DefenderHelperItemOutcome(fileName: $0.fileName, status: .cleaned, message: nil)
        }
    }
}

private struct ProviderFixture {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let helper: RecordingDefenderHelper
    let provider: PrivilegedOperationProvider

    init(helperAvailability: DefenderHelperAvailability) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: "selected.zip")
        try Data("fixture".utf8).write(to: archive)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: archive.path
        )
        helper = RecordingDefenderHelper(availability: helperAvailability)
        let rule = CleanupRule(
            id: CleanupRule.defenderDiagnostics.id,
            name: "Defender fixture",
            summary: "Fixture",
            locations: [root],
            supportsRetention: true,
            systemImage: "shield",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .permanentDelete,
                isRegenerable: false,
                requiresPrivilege: true,
                consequence: "Fixture helper"
            ),
            managedLocationDescription: nil,
            cleanupUnavailableReason: "scan-only"
        )
        let files = FilesystemProviderSupport(
            fileManager: .default,
            calendar: Calendar(identifier: .gregorian),
            runningApplicationChecker: NoRunningDefenderApplications(),
            fileTrasher: WorkspaceFileTrasher()
        )
        provider = PrivilegedOperationProvider(
            rule: rule,
            files: files,
            recursive: false,
            extensions: ["zip"],
            helper: helper
        )
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct NoRunningDefenderApplications: RunningApplicationChecking {
    @MainActor
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        []
    }
}
