import Foundation
import Testing
@testable import SpaceMender

struct SimulatorActiveStateTests {
    @Test
    func bootedUnrelatedSimulatorBlocksCleanupOfAnOtherwiseValidSelection() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let selectedID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let selectedURL = root.appending(path: selectedID)
        try fileManager.createDirectory(at: selectedURL, withIntermediateDirectories: true)

        // A different, available device is actively booted elsewhere.
        // CoreSimulator being active must block cleanup even though the
        // selected candidate itself is genuinely unavailable.
        let json = """
        {"devices":{"iOS-18":[
          {"name":"Selected Phone","udid":"\(selectedID)","isAvailable":false,"state":"Shutdown"},
          {"name":"Active Phone","udid":"11111111-2222-3333-4444-555555555555","isAvailable":true,"state":"Booted"}
        ]}}
        """
        let runner = RecordingCommandRunner(output: Data(json.utf8))
        let rule = simulatorRule(root: root)
        let provider = SimulatorCleanupProvider(
            rule: rule,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningApplications()
        )
        let item = makeItem(url: selectedURL, rule: rule, id: selectedID, stableIdentity: selectedID)

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: [item]))

        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(report.outcomes.first?.message?.localizedCaseInsensitiveContains("active") == true)
        #expect(runner.arguments == [["simctl", "list", "devices", "--json"]])
        #expect(fileManager.fileExists(atPath: selectedURL.path))
    }

    @Test
    func allShutdownDevicesAllowCleanupToProceed() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let selectedID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let selectedURL = root.appending(path: selectedID)
        try fileManager.createDirectory(at: selectedURL, withIntermediateDirectories: true)

        let json = """
        {"devices":{"iOS-18":[
          {"name":"Selected Phone","udid":"\(selectedID)","isAvailable":false,"state":"Shutdown"},
          {"name":"Idle Phone","udid":"11111111-2222-3333-4444-555555555555","isAvailable":true,"state":"Shutdown"}
        ]}}
        """
        let runner = RecordingCommandRunner(output: Data(json.utf8))
        let rule = simulatorRule(root: root)
        let provider = SimulatorCleanupProvider(
            rule: rule,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningApplications()
        )
        let item = makeItem(url: selectedURL, rule: rule, id: selectedID, stableIdentity: selectedID)

        let report = await provider.execute(plan: await provider.makeExecutionPlan(items: [item]))

        #expect(report.outcomes.map(\.status) == [.cleaned])
    }

    @Test
    func deviceStateDecodingTreatsOnlyShutdownAndMissingAsInactive() throws {
        let decoder = JSONDecoder()
        func device(state: String?) throws -> SimulatorDevice {
            let stateJSON = state.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"name":"Fixture","udid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","isAvailable":true,"state":\(stateJSON)}
            """
            return try decoder.decode(SimulatorDevice.self, from: Data(json.utf8))
        }

        #expect(try device(state: "Shutdown").isActive == false)
        #expect(try device(state: nil).isActive == false)
        #expect(try device(state: "Booted").isActive == true)
        #expect(try device(state: "Booting").isActive == true)
        #expect(try device(state: "Creating").isActive == true)
        #expect(try device(state: "Shutting Down").isActive == true)
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
        id: String,
        stableIdentity: String
    ) -> CleanupItem {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let device = attributes?[.systemNumber] as? NSNumber
        let file = attributes?[.systemFileNumber] as? NSNumber
        let resourceIdentifier = device.flatMap { device in
            file.map { "\(device.uint64Value):\($0.uint64Value)" }
        }
        return CleanupItem(
            id: id,
            providerID: rule.id,
            stableIdentity: stableIdentity,
            displayName: url.lastPathComponent,
            url: url,
            discoveredAt: Date(),
            modifiedAt: modifiedAt,
            resourceIdentifier: resourceIdentifier,
            allocatedSize: 1,
            cleanupPolicy: rule.cleanupPolicy
        )
    }

    private func simulatorRule(root: URL) -> CleanupRule {
        CleanupRule(
            id: "simulators",
            name: "Simulators",
            summary: "Test simulators",
            locations: [root],
            supportsRetention: false,
            systemImage: "iphone",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .deleteSimulator,
                isRegenerable: false,
                requiresPrivilege: false,
                consequence: "Test cleanup"
            ),
            managedLocationDescription: "Managed through simctl",
            cleanupUnavailableReason: nil
        )
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

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let output: Data
    private let lock = NSLock()
    private var argumentsStorage: [[String]] = []

    init(output: Data) {
        self.output = output
    }

    var arguments: [[String]] {
        lock.withLock { argumentsStorage }
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        lock.withLock { argumentsStorage.append(arguments) }
        return CommandResult(standardOutput: output, standardError: Data(), terminationStatus: 0)
    }
}
