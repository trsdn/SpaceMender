import Foundation

/// Discovers the npm cache root(s) actually configured on this Mac, rather
/// than assuming a single hardcoded location. npm's cache path can be
/// overridden per installation through `.npmrc` or the `npm_config_cache`
/// environment variable, and a developer machine commonly has more than one
/// npm installation (Homebrew, the official installer, nvm, Volta, ...).
protocol NpmCacheRootDiscovering: Sendable {
    func discoverCacheRoots() async -> [URL]
}

/// Finds npm executables at well-known Apple Silicon, Intel, system, nvm,
/// and Volta locations and asks each one for its configured cache directory
/// with `npm config get cache`. GUI apps do not inherit a login shell's
/// `PATH`, so SpaceMender checks fixed candidate locations directly instead
/// of relying on `PATH` lookup.
final class NpmEnvironmentCacheRootDiscoverer: NpmCacheRootDiscovering, @unchecked Sendable {
    private let candidateExecutables: [URL]
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let homeDirectory: URL

    init(
        candidateExecutables: [URL],
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.candidateExecutables = candidateExecutables
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.homeDirectory = homeDirectory
    }

    convenience init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: any CommandRunning
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            URL(filePath: "/opt/homebrew/bin/npm"), // Apple Silicon Homebrew
            URL(filePath: "/usr/local/bin/npm"), // Intel Homebrew or the official installer
            URL(filePath: "/usr/bin/npm")
        ]
        let nvmDirectory = environment["NVM_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? home.appending(path: ".nvm", directoryHint: .isDirectory)
        let nvmNodeVersions = nvmDirectory.appending(
            path: "versions/node",
            directoryHint: .isDirectory
        )
        if let versionDirectories = try? fileManager.contentsOfDirectory(
            at: nvmNodeVersions,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(
                contentsOf: versionDirectories.map { $0.appending(path: "bin/npm") }
            )
        }
        candidates.append(home.appending(path: ".volta/bin/npm"))
        self.init(
            candidateExecutables: candidates,
            fileManager: fileManager,
            commandRunner: commandRunner,
            homeDirectory: home
        )
    }

    func discoverCacheRoots() async -> [URL] {
        var roots: Set<String> = []
        for executable in candidateExecutables {
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                continue
            }
            guard let result = try? await commandRunner.run(
                executable: executable,
                arguments: ["config", "get", "cache"]
            ), result.terminationStatus == 0 else {
                continue
            }
            let text = String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Defense in depth: never trust an npm configuration that
            // reports the filesystem root or the user's whole home
            // directory as its cache, even though scoped root-preservation
            // and symlink/root validation would still confine any deletion
            // to declared roots regardless.
            guard !text.isEmpty,
                  text.hasPrefix("/"),
                  text != "/",
                  text != homeDirectory.standardizedFileURL.path else {
                continue
            }
            roots.insert(text)
        }
        return roots.sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

/// Discovers npm's cache root(s) and treats each root's known `_cacache`
/// (package content cache) and `_npx` (npx install cache) subdirectories as
/// preserved-root candidates: each root is kept, and only its validated
/// contents are permanently deleted. Falls back to the historical
/// `~/.npm/_cacache` and `~/.npm/_npx` defaults declared on the rule when
/// discovery finds nothing, so behavior never regresses when npm isn't
/// found at any known location.
final class NpmCacheCleanupProvider: CleanupProvider, @unchecked Sendable {
    private let baseRule: CleanupRule
    private let files: FilesystemProviderSupport
    private let discoverer: any NpmCacheRootDiscovering
    private let lock = NSLock()
    private var discoveredChildRootsStorage: [URL] = []

    init(
        rule: CleanupRule,
        files: FilesystemProviderSupport,
        discoverer: any NpmCacheRootDiscovering
    ) {
        baseRule = rule
        self.files = files
        self.discoverer = discoverer
    }

    /// When discovery finds real npm cache roots, those roots — and only
    /// those roots — govern this rule's locations, so a stale historical
    /// default never sits alongside genuinely discovered roots. The
    /// declared defaults apply only when discovery finds nothing at all.
    var rule: CleanupRule {
        let discoveredRoots = lock.withLock { discoveredChildRootsStorage }
        guard !discoveredRoots.isEmpty else {
            return baseRule
        }
        var uniqueLocations: [URL] = []
        for root in discoveredRoots {
            let standardizedPath = root.standardizedFileURL.path
            guard !uniqueLocations.contains(where: { $0.standardizedFileURL.path == standardizedPath }) else {
                continue
            }
            uniqueLocations.append(root)
        }
        return CleanupRule(
            id: baseRule.id,
            name: baseRule.name,
            summary: baseRule.summary,
            locations: uniqueLocations,
            supportsRetention: baseRule.supportsRetention,
            systemImage: baseRule.systemImage,
            caution: baseRule.caution,
            affectedApplicationBundleIdentifiers: baseRule.affectedApplicationBundleIdentifiers,
            affectedApplicationNames: baseRule.affectedApplicationNames,
            safety: baseRule.safety,
            managedLocationDescription: baseRule.managedLocationDescription,
            cleanupUnavailableReason: baseRule.cleanupUnavailableReason,
            defaultRetentionDays: baseRule.defaultRetentionDays
        )
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        let discoveredCacheRoots = await discoverer.discoverCacheRoots()
        let childRoots = discoveredCacheRoots.flatMap { cacheRoot in
            ["_cacache", "_npx"].map {
                cacheRoot.appending(path: $0, directoryHint: .isDirectory)
            }
        }
        lock.withLock { discoveredChildRootsStorage = childRoots }
        return try files.scanFixedRoots(rule: rule, now: now)
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(for: item, rule: rule, expected: .exactRoot)
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(plan, rule: rule, expected: .exactRoot)
    }
}
