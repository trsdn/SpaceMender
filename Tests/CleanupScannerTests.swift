import Foundation
import Testing
@testable import SpaceMender

struct CleanupScannerTests {
    @Test
    func scanReturnsOnlyMatchingFilesOlderThanCutoff() async throws {
        let fileManager = FileManager.default
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let oldArchive = directory.appending(path: "old.zip")
        let recentArchive = directory.appending(path: "recent.zip")
        let unrelatedFile = directory.appending(path: "old.log")
        try Data(repeating: 1, count: 1_024).write(to: oldArchive)
        try Data(repeating: 1, count: 512).write(to: recentArchive)
        try Data(repeating: 1, count: 256).write(to: unrelatedFile)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try setAge(of: oldArchive, days: 40, relativeTo: now)
        try setAge(of: recentArchive, days: 2, relativeTo: now)
        try setAge(of: unrelatedFile, days: 40, relativeTo: now)

        let rule = makeRule(
            location: directory,
            scanKind: .files(recursive: false, extensions: ["zip"])
        )
        let result = try await CleanupScanner().scan(
            rule: rule,
            olderThanDays: 30,
            now: now
        )

        #expect(result.items.map(\.displayName) == ["old.zip"])
        #expect(result.reclaimableBytes > 0)
        #expect(result.items.first?.providerID == rule.id)
        #expect(result.items.first?.discoveredAt == now)
        #expect(result.items.first?.resourceIdentifier != nil)
        #expect(result.items.first?.cleanupPolicy == .permanentDelete)
    }

    @Test
    func recursiveScanFindsOldNestedLogs() async throws {
        let fileManager = FileManager.default
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let nested = directory.appending(path: "App", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let log = nested.appending(path: "old.log")
        try Data(repeating: 1, count: 256).write(to: log)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try setAge(of: log, days: 60, relativeTo: now)
        let rule = makeRule(
            location: directory,
            scanKind: .files(recursive: true, extensions: nil)
        )

        let result = try await CleanupScanner().scan(
            rule: rule,
            olderThanDays: 30,
            now: now
        )

        #expect(result.items.map(\.displayName) == ["old.log"])
    }

    @Test
    func fixedLocationsAreReportedAsGroupedItems() async throws {
        let fileManager = FileManager.default
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        try Data(repeating: 1, count: 2_048)
            .write(to: directory.appending(path: "cache.data"))
        let rule = makeRule(location: directory, scanKind: .fixedLocations)

        let result = try await CleanupScanner().scan(rule: rule, olderThanDays: 30)

        #expect(result.items.count == 1)
        #expect(result.items.first?.displayName == directory.lastPathComponent)
        #expect(result.reclaimableBytes > 0)
    }

    @Test
    func missingLocationProducesEmptyResult() async throws {
        let location = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let rule = makeRule(
            location: location,
            scanKind: .files(recursive: false, extensions: ["zip"])
        )

        let result = try await CleanupScanner().scan(rule: rule, olderThanDays: 30)

        #expect(result.items.isEmpty)
        #expect(result.reclaimableBytes == 0)
    }

    @Test
    func simulatorJSONDiscoveryUsesStructuredAvailability() async throws {
        let fileManager = FileManager.default
        let devicesRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: devicesRoot) }

        let selectedID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let availableID = "11111111-2222-3333-4444-555555555555"
        try fileManager.createDirectory(
            at: devicesRoot.appending(path: selectedID),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: devicesRoot.appending(path: availableID),
            withIntermediateDirectories: true
        )
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {"name":"Unavailable Phone","udid":"\(selectedID)","isAvailable":false},
              {"name":"Available Phone","udid":"\(availableID)","isAvailable":true}
            ]
          }
        }
        """
        let runner = ScannerCommandRunner(output: Data(json.utf8))
        let rule = CleanupRule(
            id: "simulators",
            name: "Simulators",
            summary: "Test",
            locations: [devicesRoot],
            scanKind: .unavailableSimulators,
            cleanupAction: .deleteUnavailableSimulators,
            cleanupPolicy: .deleteSimulator,
            supportsRetention: false,
            systemImage: "iphone",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )

        let result = try await CleanupScanner(commandRunner: runner).scan(
            rule: rule,
            olderThanDays: 0
        )

        #expect(result.items.map(\.id) == [selectedID])
        #expect(result.items.map(\.displayName) == ["Unavailable Phone"])
        #expect(runner.arguments == [["simctl", "list", "devices", "unavailable", "--json"]])
    }

    private func makeRule(
        location: URL,
        scanKind: CleanupRule.ScanKind
    ) -> CleanupRule {
        CleanupRule(
            id: "test",
            name: "Test",
            summary: "Test files",
            locations: [location],
            scanKind: scanKind,
            cleanupAction: .deleteItems,
            cleanupPolicy: scanKind.isFixedLocation
                ? .permanentDeleteContents
                : .permanentDelete,
            supportsRetention: true,
            systemImage: "doc",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setAge(of url: URL, days: Int, relativeTo now: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-Double(days) * 86_400)],
            ofItemAtPath: url.path
        )
    }
}

private extension CleanupRule.ScanKind {
    var isFixedLocation: Bool {
        if case .fixedLocations = self {
            return true
        }
        return false
    }
}

private final class ScannerCommandRunner: CommandRunning, @unchecked Sendable {
    private let output: Data
    private let lock = NSLock()
    private(set) var arguments: [[String]] = []

    init(output: Data) {
        self.output = output
    }

    func run(executable: URL, arguments: [String]) throws -> CommandResult {
        lock.withLock {
            self.arguments.append(arguments)
        }
        return CommandResult(
            standardOutput: output,
            standardError: Data(),
            terminationStatus: 0
        )
    }
}
