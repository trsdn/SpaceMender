import Foundation

/// Cleans Microsoft Edge and Google Chrome cache data with per-profile
/// precision: each profile subdirectory under a browser's cache root (for
/// example `Default`, `Profile 1`, `Guest Profile`) becomes its own
/// candidate, so users can select individual profiles rather than an entire
/// browser's combined cache in one lump sum.
///
/// As defense in depth beyond the fact that `~/Library/Caches/...` never
/// contains cookies, history, sessions, extensions, or profile data in real
/// Chrome/Edge releases (that data lives under `~/Library/Application
/// Support/...` instead), this provider also explicitly refuses to ever
/// select or delete anything whose name matches `sensitiveDataNames`, at any
/// nesting depth, and fails an entire candidate closed if one is found
/// rather than deleting around it.
final class BrowserProfileCacheCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let files: FilesystemProviderSupport

    /// Names SpaceMender must never select or delete, even if they somehow
    /// appeared inside a declared cache root. These are the real on-disk
    /// names Chromium-based browsers use for cookies, history, saved
    /// passwords, autofill, bookmarks, favicons, extensions, sync state,
    /// and other per-profile data under `~/Library/Application Support`.
    static let sensitiveDataNames: Set<String> = [
        "cookies", "cookies-journal",
        "history", "history-journal", "history provider cache", "history index",
        "top sites", "top sites-journal",
        "visited links",
        "login data", "login data-journal", "login data for account",
        "web data", "web data-journal",
        "bookmarks", "bookmarks.bak",
        "favicons", "favicons-journal",
        "extensions", "extension state", "extension rules", "extension scripts",
        "sync data", "sync data.trash", "sync extension settings",
        "session storage", "sessions", "current session", "current tabs",
        "last session", "last tabs",
        "local storage", "indexeddb",
        "network persistent state", "transportsecurity",
        "preferences", "secure preferences", "shortcuts", "preferredapps",
        "profile.ico"
    ]

    init(rule: CleanupRule, files: FilesystemProviderSupport) {
        self.rule = rule
        self.files = files
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        try files.scanCacheRootChildren(
            rule: rule,
            excludedNames: Self.sensitiveDataNames,
            now: now
        )
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(
            for: item,
            rule: rule,
            expected: .cacheRootChild(excludedNames: Self.sensitiveDataNames)
        )
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(
            plan,
            rule: rule,
            expected: .cacheRootChild(excludedNames: Self.sensitiveDataNames)
        )
    }
}
