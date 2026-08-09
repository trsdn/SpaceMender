import Foundation
import Testing
@testable import SpaceMender

struct HomebrewCleanupProviderTests {
    /// Real `brew cleanup --dry-run` output captured from a live Apple
    /// Silicon Homebrew install (Homebrew 6.0.15), reproducing the
    /// warning-heavy shape the plan specifically calls out: dozens of
    /// unrelated "Warning: Skipping ..." lines about outdated local
    /// formula versions, followed by removal lines and a final estimate.
    private static let realWarningHeavyOutput = """
    Warning: Skipping ada-url: most recent version 4.0.0 not installed
    Warning: Skipping azure-cli: most recent version 2.89.0 not installed
    Warning: Skipping c-ares: most recent version 1.34.8 not installed
    Warning: Skipping certifi: most recent version 2026.7.22 not installed
    Warning: Skipping cffi: most recent version 2.1.1 not installed
    Warning: Skipping dav1d: most recent version 1.5.4 not installed
    Warning: Skipping deno: most recent version 2.9.5 not installed
    Warning: Skipping ffmpeg: most recent version 8.1.2_1 not installed
    Warning: Skipping fmt: most recent version 12.2.0 not installed
    Warning: Skipping fontconfig: most recent version 2.18.3 not installed
    Warning: Skipping gdk-pixbuf: most recent version 2.44.7 not installed
    Warning: Skipping gh: most recent version 2.97.0 not installed
    Warning: Skipping glib: most recent version 2.88.3 not installed
    Warning: Skipping harfbuzz: most recent version 14.3.0 not installed
    Would remove: /opt/homebrew/Cellar/ca-certificates/2026-05-14 (4 files, 200.6KB)
    Would remove: /opt/homebrew/Cellar/sqlite/3.53.3 (13 files, 5.3MB)
    Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.5_1 (1,707 files, 34.6MB)
    ==> This operation would free approximately 40.2MB of disk space.
    """

    @Test
    func discoversAppleSiliconHomebrewWhenPresent() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: ["/opt/homebrew/bin/brew"])
        let runner = FixedOutputCommandRunner(standardOutput: "")
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        _ = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(runner.recordedExecutables == ["/opt/homebrew/bin/brew"])
    }

    @Test
    func discoversIntelHomebrewWhenAppleSiliconIsMissing() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: ["/usr/local/bin/brew"])
        let runner = FixedOutputCommandRunner(standardOutput: "")
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        _ = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(runner.recordedExecutables == ["/usr/local/bin/brew"])
    }

    @Test
    func prefersConfiguredHomebrewPrefixOverStandardLocations() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: [
            "/custom/homebrew/bin/brew", "/opt/homebrew/bin/brew", "/usr/local/bin/brew"
        ])
        let runner = FixedOutputCommandRunner(standardOutput: "")
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: ["HOMEBREW_PREFIX": "/custom/homebrew"]
        )

        _ = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(runner.recordedExecutables == ["/custom/homebrew/bin/brew"])
    }

    @Test
    func missingHomebrewProducesNoCandidateWithoutError() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: [])
        let runner = FixedOutputCommandRunner(standardOutput: "")
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(items.isEmpty)
        #expect(runner.recordedExecutables.isEmpty)
    }

    @Test
    func warningHeavyRealOutputParsesKnownEstimateAndSummarizesWarningsInsteadOfRawDump() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: ["/opt/homebrew/bin/brew"])
        let runner = FixedOutputCommandRunner(standardOutput: Self.realWarningHeavyOutput)
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)
        let item = try #require(items.first)

        #expect(!item.hasUnknownSize)
        #expect(item.allocatedSize == 40_200_000)
        let notice = try #require(item.notice)
        #expect(notice.hasPrefix("Warning:"))
        #expect(notice.count < Self.realWarningHeavyOutput.count)
        #expect(!notice.contains("Would remove:"), "Notice must summarize warnings, not repeat the full command output")
    }

    @Test
    func unparseableOrLocalizedOutputWithRemovalIndicationShowsUnknownEstimate() async throws {
        // Simulates a future/localized Homebrew release whose summary
        // sentence this parser does not recognize, while removal activity
        // clearly did happen ("Would remove:" is present). SpaceMender must
        // never silently report "nothing to clean" in this case.
        let unparseableOutput = """
        Would remove: /opt/homebrew/Cellar/example/1.0 (3 files, 1.2MB)
        ==> Diese Operation gibt ungefähr 1,2MB Speicherplatz frei.
        """
        let fileManager = FakeExecutableFileManager(executablePaths: ["/opt/homebrew/bin/brew"])
        let runner = FixedOutputCommandRunner(standardOutput: unparseableOutput)
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)
        let item = try #require(items.first)

        #expect(item.hasUnknownSize)
        #expect(item.allocatedSize == 0)
    }

    @Test
    func trulyEmptyOutputReportsNothingToCleanRatherThanUnknown() async throws {
        let fileManager = FakeExecutableFileManager(executablePaths: ["/opt/homebrew/bin/brew"])
        let runner = FixedOutputCommandRunner(standardOutput: "")
        let provider = ExternalCommandCleanupProvider.homebrew(
            rule: .homebrewCleanup,
            fileManager: fileManager,
            commandRunner: runner,
            runningApplicationChecker: NoRunningFixtureApplications(),
            environment: [:]
        )

        let items = try await provider.discover(olderThanDays: 0, now: .now)

        #expect(items.isEmpty)
    }

    @Test
    func homebrewRuleDeclaresDiscoveryConsequenceAndNoRetentionControl() {
        let rule = CleanupRule.homebrewCleanup
        #expect(!rule.supportsRetention)
        #expect(rule.defaultRetentionDays == nil)
        #expect(rule.safety.consequence.localizedCaseInsensitiveContains("unknown"))
        #expect(rule.locations.map(\.path).contains("/opt/homebrew"))
        #expect(rule.locations.map(\.path).contains("/usr/local"))
    }
}

/// Overrides `isExecutableFile` so candidate-path discovery can be tested
/// deterministically without depending on this machine's real Homebrew
/// installation location.
private final class FakeExecutableFileManager: FileManager, @unchecked Sendable {
    private let executablePaths: Set<String>

    init(executablePaths: [String]) {
        self.executablePaths = Set(executablePaths)
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class FixedOutputCommandRunner: CommandRunning, @unchecked Sendable {
    private let standardOutput: String
    private let lock = NSLock()
    private var executablesStorage: [String] = []

    init(standardOutput: String) {
        self.standardOutput = standardOutput
    }

    var recordedExecutables: [String] {
        lock.withLock { executablesStorage }
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        lock.withLock { executablesStorage.append(executable.path) }
        return CommandResult(
            standardOutput: Data(standardOutput.utf8),
            standardError: Data(),
            terminationStatus: 0
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
