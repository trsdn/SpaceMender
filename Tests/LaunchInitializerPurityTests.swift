import Foundation
import Testing
@testable import SpaceMender

/// Guards issue #4: launch-time work must not perform filesystem probes on the main thread.
///
/// The point is not micro-optimisation — measured on an idle machine the whole catalog costs
/// well under 2 ms. The point is that `contentsOfDirectory` has **no bounded latency**. On a
/// network home directory, a stalled volume, or during a contended login, it can block for
/// seconds, and it does so before the first window is drawn.
struct LaunchInitializerPurityTests {
    @Test
    func npmDiscovererInitializerTouchesNoFilesystem() {
        let fileManager = RecordingFileManager()

        _ = NpmEnvironmentCacheRootDiscoverer(
            fileManager: fileManager,
            environment: ["NVM_DIR": "/tmp/does-not-matter"],
            commandRunner: NeverRunningCommandRunner()
        )

        #expect(
            fileManager.directoryListings.isEmpty,
            """
            Building the candidate list enumerates nvm's installed versions. Doing that in the \
            initializer blocks app startup on filesystem I/O of unbounded duration.
            """
        )
    }

    @Test
    func npmCandidateListIsBuiltWhenDiscoveryActuallyRuns() async {
        let fileManager = RecordingFileManager()
        let discoverer = NpmEnvironmentCacheRootDiscoverer(
            fileManager: fileManager,
            environment: ["NVM_DIR": "/tmp/does-not-matter"],
            commandRunner: NeverRunningCommandRunner()
        )

        _ = await discoverer.discoverCacheRoots()

        #expect(
            fileManager.directoryListings.count == 1,
            "Deferred, not dropped: the nvm probe must still happen inside the async path"
        )
    }

    /// Deferring is also a correctness fix: the candidate list used to be frozen at launch.
    @Test
    func eachDiscoveryPassRebuildsTheCandidateList() async {
        let fileManager = RecordingFileManager()
        let discoverer = NpmEnvironmentCacheRootDiscoverer(
            fileManager: fileManager,
            environment: ["NVM_DIR": "/tmp/does-not-matter"],
            commandRunner: NeverRunningCommandRunner()
        )

        _ = await discoverer.discoverCacheRoots()
        _ = await discoverer.discoverCacheRoots()

        #expect(
            fileManager.directoryListings.count == 2,
            """
            A node version installed after launch must be found without restarting the app. \
            A list captured once in the initializer could never notice it.
            """
        )
    }

    /// The explicit-candidates initializer is what tests and callers with a known list use; it
    /// must stay free of probing too.
    @Test
    func explicitCandidateListPerformsNoProbing() {
        let fileManager = RecordingFileManager()

        _ = NpmEnvironmentCacheRootDiscoverer(
            candidateExecutables: [URL(filePath: "/usr/bin/npm")],
            fileManager: fileManager,
            commandRunner: NeverRunningCommandRunner(),
            homeDirectory: URL(filePath: "/tmp/home", directoryHint: .isDirectory)
        )

        #expect(fileManager.directoryListings.isEmpty)
    }
}

/// Records directory enumerations so a test can prove none happened, instead of inferring it
/// from timings — which would be flaky and would not distinguish "fast" from "not done".
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [URL] = []

    var directoryListings: [URL] {
        lock.withLock { listings }
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        lock.withLock { listings.append(url) }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

private struct NeverRunningCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        throw CocoaError(.fileNoSuchFile)
    }
}
