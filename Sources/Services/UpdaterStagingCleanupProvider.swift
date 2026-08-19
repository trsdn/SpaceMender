import Foundation

/// Cleans staging folders that app self-updaters leave in `~/Library/Caches` after an update
/// has already been installed.
///
/// Two conventions cover the common cases on macOS:
///
/// - Squirrel.Mac (Electron apps: VS Code, Slack, Discord, …) creates `<bundle id>.ShipIt`.
/// - Several Electron updaters create `<app>-updater`.
///
/// Both are working directories: the updater recreates its own on the next run, and neither
/// holds user data. That is the whole reason this can be offered as a cleanup candidate at all.
///
/// The declared root is `~/Library/Caches`, which contains everything the user has ever cached,
/// so the naming convention is not merely a discovery filter here — it is enforced again during
/// validation via `.cacheRootChildWithSuffix`. Discovery alone deciding what may be deleted
/// would make any bug in the scan a licence to delete an unrelated cache.
final class UpdaterStagingCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let files: FilesystemProviderSupport

    /// Matched case-insensitively against the end of a child directory's name.
    static let stagingSuffixes: Set<String> = [".shipit", "-updater"]

    init(rule: CleanupRule, files: FilesystemProviderSupport) {
        self.rule = rule
        self.files = files
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        try files.scanCacheRootChildren(
            rule: rule,
            matchingSuffixes: Self.stagingSuffixes,
            now: now
        )
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(
            for: item,
            rule: rule,
            expected: .cacheRootChildWithSuffix(allowedSuffixes: Self.stagingSuffixes)
        )
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(
            plan,
            rule: rule,
            expected: .cacheRootChildWithSuffix(allowedSuffixes: Self.stagingSuffixes)
        )
    }
}
