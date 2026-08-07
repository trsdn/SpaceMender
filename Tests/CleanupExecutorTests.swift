import Foundation
import Testing
@testable import SpaceMender

@MainActor
struct CleanupExecutorTests {
    @Test
    func simulatorCleanupPassesOnlySelectedRevalidatedUDIDs() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let selectedID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let unselectedID = "11111111-2222-3333-4444-555555555555"
        let selectedURL = root.appending(path: selectedID)
        let unselectedURL = root.appending(path: unselectedID)
        try fileManager.createDirectory(at: selectedURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unselectedURL, withIntermediateDirectories: true)

        let runner = RecordingCommandRunner(
            simulatorJSON: simulatorJSON(unavailableIDs: [selectedID, unselectedID])
        )
        let rule = simulatorRule(root: root)
        let selected = makeItem(
            url: selectedURL,
            rule: rule,
            id: selectedID,
            stableIdentity: selectedID
        )

        let report = await CleanupExecutor(
            commandRunner: runner,
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [selected])

        #expect(report.outcomes.map(\.status) == [.cleaned])
        #expect(
            runner.recordedArguments == [
                ["simctl", "list", "devices", "unavailable", "--json"],
                ["simctl", "delete", selectedID]
            ]
        )
        if runner.recordedArguments.count > 1 {
            #expect(!runner.recordedArguments[1].contains(unselectedID))
        }
    }

    @Test
    func simulatorThatBecameAvailableIsSkipped() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let identifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let device = root.appending(path: identifier)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let runner = RecordingCommandRunner(simulatorJSON: simulatorJSON(unavailableIDs: []))
        let rule = simulatorRule(root: root)

        let report = await CleanupExecutor(
            commandRunner: runner,
            runningApplicationChecker: NoRunningApplications()
        ).clean(
            rule: rule,
            items: [
                makeItem(
                    url: device,
                    rule: rule,
                    id: identifier,
                    stableIdentity: identifier
                )
            ]
        )

        #expect(report.outcomes.map(\.status) == [.skippedChanged])
        #expect(runner.recordedArguments.count == 1)
        #expect(FileManager.default.fileExists(atPath: device.path))
    }

    @Test
    func changedCandidateIsSkippedAndRemainsOnDisk() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appending(path: "old.log")
        try Data("before".utf8).write(to: file)

        let rule = fileRule(root: root)
        let item = makeItem(url: file, rule: rule)
        try fileManager.setAttributes(
            [.modificationDate: item.discoveredAt.addingTimeInterval(60)],
            ofItemAtPath: file.path
        )

        let report = await CleanupExecutor(
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [item])

        #expect(report.outcomes.map(\.status) == [.skippedChanged])
        #expect(fileManager.fileExists(atPath: file.path))
    }

    @Test
    func affectedRunningApplicationBlocksCleanup() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appending(path: "old.log")
        try Data("keep".utf8).write(to: file)
        let rule = fileRule(root: root)

        let report = await CleanupExecutor(
            runningApplicationChecker: FixedRunningApplications(names: ["Test Browser"])
        ).clean(rule: rule, items: [makeItem(url: file, rule: rule)])

        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(report.outcomes.first?.message?.contains("Quit Test Browser") == true)
        #expect(fileManager.fileExists(atPath: file.path))
    }

    @Test
    func cacheCleanupRemovesContentsButPreservesRootMetadata() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: root.path)
        try Data("visible".utf8).write(to: root.appending(path: "cache.data"))
        try Data("hidden".utf8).write(to: root.appending(path: ".hidden"))

        let rule = cacheRule(root: root)
        let item = makeItem(url: root, rule: rule)
        let attributesBefore = try fileManager.attributesOfItem(atPath: root.path)

        let report = await CleanupExecutor(
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [item])

        let attributesAfter = try fileManager.attributesOfItem(atPath: root.path)
        let remaining = try fileManager.contentsOfDirectory(atPath: root.path)
        #expect(report.outcomes.map(\.status) == [.cleaned])
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(remaining.isEmpty)
        #expect(
            attributesAfter[.posixPermissions] as? NSNumber
                == attributesBefore[.posixPermissions] as? NSNumber
        )
        #expect(attributesAfter[.ownerAccountID] as? NSNumber == attributesBefore[.ownerAccountID] as? NSNumber)
    }

    @Test
    func symlinkSurprisePreventsCacheCleanup() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let outsideFile = outside.appending(path: "keep.data")
        try Data("keep".utf8).write(to: outsideFile)
        try fileManager.createSymbolicLink(
            at: root.appending(path: "escape"),
            withDestinationURL: outsideFile
        )

        let rule = cacheRule(root: root)
        let report = await CleanupExecutor(
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [makeItem(url: root, rule: rule)])

        #expect(report.outcomes.map(\.status) == [.skippedChanged])
        #expect(fileManager.fileExists(atPath: outsideFile.path))
        #expect(fileManager.fileExists(atPath: root.appending(path: "escape").path))
    }

    @Test
    func cacheContentCreatedAfterScanIsSkipped() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appending(path: "old.cache"))
        let rule = cacheRule(root: root)
        let item = makeItem(url: root, rule: rule)
        let newFile = root.appending(path: "new.cache")
        try Data("new".utf8).write(to: newFile)
        try fileManager.setAttributes(
            [.modificationDate: item.discoveredAt.addingTimeInterval(60)],
            ofItemAtPath: newFile.path
        )

        let report = await CleanupExecutor(
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [item])

        #expect(report.outcomes.map(\.status) == [.skippedChanged])
        #expect(fileManager.fileExists(atPath: root.appending(path: "old.cache").path))
        #expect(fileManager.fileExists(atPath: newFile.path))
    }

    @Test
    func partialCleanupReturnsPerItemOutcomes() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cleanable = root.appending(path: "cleanable.log")
        let changed = root.appending(path: "changed.log")
        try Data("one".utf8).write(to: cleanable)
        try Data("two".utf8).write(to: changed)
        let rule = fileRule(root: root)
        let cleanableItem = makeItem(url: cleanable, rule: rule)
        let changedItem = makeItem(url: changed, rule: rule)
        try fileManager.setAttributes(
            [.modificationDate: changedItem.discoveredAt.addingTimeInterval(60)],
            ofItemAtPath: changed.path
        )

        let report = await CleanupExecutor(
            runningApplicationChecker: NoRunningApplications()
        ).clean(rule: rule, items: [cleanableItem, changedItem])

        #expect(report.outcomes.map(\.status) == [.cleaned, .skippedChanged])
        #expect(!fileManager.fileExists(atPath: cleanable.path))
        #expect(fileManager.fileExists(atPath: changed.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(
        url: URL,
        rule: CleanupRule,
        id: String? = nil,
        stableIdentity: String? = nil
    ) -> CleanupItem {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let device = attributes?[.systemNumber] as? NSNumber
        let file = attributes?[.systemFileNumber] as? NSNumber
        let resourceIdentifier = device.flatMap { device in
            file.map { "\(device.uint64Value):\($0.uint64Value)" }
        }
        return CleanupItem(
            id: id ?? url.path,
            providerID: rule.id,
            stableIdentity: stableIdentity ?? url.standardizedFileURL.path,
            displayName: url.lastPathComponent,
            url: url,
            discoveredAt: Date(),
            modifiedAt: modifiedAt,
            resourceIdentifier: resourceIdentifier,
            allocatedSize: 1,
            cleanupPolicy: rule.cleanupPolicy
        )
    }

    private func fileRule(root: URL) -> CleanupRule {
        CleanupRule(
            id: "files",
            name: "Files",
            summary: "Test files",
            locations: [root],
            scanKind: .files(recursive: false, extensions: ["log"]),
            cleanupAction: .deleteItems,
            cleanupPolicy: .permanentDelete,
            supportsRetention: true,
            systemImage: "doc",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )
    }

    private func cacheRule(root: URL) -> CleanupRule {
        CleanupRule(
            id: "cache",
            name: "Cache",
            summary: "Test cache",
            locations: [root],
            scanKind: .fixedLocations,
            cleanupAction: .deleteItems,
            cleanupPolicy: .permanentDeleteContents,
            supportsRetention: false,
            systemImage: "externaldrive",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )
    }

    private func simulatorRule(root: URL) -> CleanupRule {
        CleanupRule(
            id: "simulators",
            name: "Simulators",
            summary: "Test simulators",
            locations: [root],
            scanKind: .unavailableSimulators,
            cleanupAction: .deleteUnavailableSimulators,
            cleanupPolicy: .deleteSimulator,
            supportsRetention: false,
            systemImage: "iphone",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )
    }

    private func simulatorJSON(unavailableIDs: [String]) -> Data {
        let devices = unavailableIDs.map {
            #"{"name":"Phone","udid":"\#($0)","isAvailable":false}"#
        }.joined(separator: ",")
        return Data(#"{"devices":{"runtime":[\#(devices)]}}"#.utf8)
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

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let simulatorJSON: Data
    private var argumentsStorage: [[String]] = []

    init(simulatorJSON: Data) {
        self.simulatorJSON = simulatorJSON
    }

    var recordedArguments: [[String]] {
        lock.withLock { argumentsStorage }
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        lock.withLock {
            argumentsStorage.append(arguments)
        }
        return CommandResult(
            standardOutput: arguments.contains("list") ? simulatorJSON : Data(),
            standardError: Data(),
            terminationStatus: 0
        )
    }
}
