import Foundation

struct CleanupSafetyMetadata: Sendable {
    let cleanupPolicy: CleanupPolicy
    let isRegenerable: Bool
    let requiresPrivilege: Bool
    let consequence: String
}

struct CleanupRule: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let locations: [URL]
    let supportsRetention: Bool
    let systemImage: String
    let caution: String?
    let affectedApplicationBundleIdentifiers: Set<String>
    let affectedApplicationNames: Set<String>
    let safety: CleanupSafetyMetadata
    let managedLocationDescription: String?
    let cleanupUnavailableReason: String?
    /// The provider's own default retention age, in days. `nil` when the
    /// provider does not expose an age control (vendor-state or fixed-cache
    /// providers), matching `supportsRetention == false`. Each provider
    /// declares this explicitly rather than relying on one shared,
    /// application-wide default so switching categories can never leak a
    /// retention value between unrelated providers.
    var defaultRetentionDays: Int? = nil

    var cleanupPolicy: CleanupPolicy {
        safety.cleanupPolicy
    }

    func withCleanupUnavailableReason(_ reason: String?) -> CleanupRule {
        CleanupRule(
            id: id,
            name: name,
            summary: summary,
            locations: locations,
            supportsRetention: supportsRetention,
            systemImage: systemImage,
            caution: caution,
            affectedApplicationBundleIdentifiers: affectedApplicationBundleIdentifiers,
            affectedApplicationNames: affectedApplicationNames,
            safety: safety,
            managedLocationDescription: managedLocationDescription,
            cleanupUnavailableReason: reason,
            defaultRetentionDays: defaultRetentionDays
        )
    }

    var locationDescription: String {
        managedLocationDescription ?? locations.map(\.path).joined(separator: "\n")
    }

    func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return locations.contains { location in
            let root = location.standardizedFileURL.resolvingSymlinksInPath().path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }
}

extension CleanupRule {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let defenderDiagnostics = CleanupRule(
        id: "microsoft-defender-diagnostics",
        name: "Defender diagnostics",
        summary: "Diagnostic ZIP archives left behind by Microsoft Defender.",
        locations: [
            URL(
                filePath: "/Library/Application Support/Microsoft/Defender/wdavdiag",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: true,
        systemImage: "shield.lefthalf.filled",
        caution: nil,
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDelete,
            isRegenerable: false,
            requiresPrivilege: true,
            consequence: "Requires the fixed-operation privileged helper."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason:
            "Cleanup is scan-only until SpaceMender’s signed privileged helper is installed.",
        defaultRetentionDays: 30
    )

    static let unavailableSimulators = CleanupRule(
        id: "xcode-unavailable-simulators",
        name: "Unavailable simulators",
        summary: "Simulator devices whose runtimes are no longer installed.",
        locations: [
            home.appending(
                path: "Library/Developer/CoreSimulator/Devices",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: false,
        systemImage: "iphone.slash",
        caution: "Their simulator app data will also be removed.",
        affectedApplicationBundleIdentifiers: [
            "com.apple.iphonesimulator",
            "com.apple.CoreSimulator.CoreSimulatorService"
        ],
        affectedApplicationNames: ["Simulator", "CoreSimulatorService"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .deleteSimulator,
            isRegenerable: false,
            requiresPrivilege: false,
            consequence: "Deletes only the selected unavailable simulator devices through simctl. "
                + "SpaceMender blocks this cleanup while any simulator is booted, booting, "
                + "shutting down, or being created."
        ),
        managedLocationDescription: "Managed through xcrun simctl",
        cleanupUnavailableReason: nil
    )

    /// DerivedData's activity date is a bounded heuristic, not a full
    /// recursive scan: it is the newest modification date among the project
    /// root itself and its *immediate* `Build` and `Index*` (for example
    /// `Index.noindex`) child directories only. Nothing deeper in the tree is
    /// visited when deciding whether a project is still active, which keeps
    /// scanning fast on large caches. See `FilesystemProviderSupport`'s
    /// `boundedActivityDate(for:fallback:fileManager:)`.
    static let xcodeDerivedData = CleanupRule(
        id: "xcode-derived-data",
        name: "Xcode DerivedData",
        summary: "Build products and indexes that Xcode can regenerate.",
        locations: [
            home.appending(
                path: "Library/Developer/Xcode/DerivedData",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: true,
        systemImage: "hammer",
        caution: "Close Xcode first. The next build and index may take longer.",
        affectedApplicationBundleIdentifiers: ["com.apple.dt.Xcode"],
        affectedApplicationNames: ["Xcode"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDelete,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes regenerable build products and indexes. Blocked "
                + "while Xcode is running; quit Xcode, rescan, and try again."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil,
        defaultRetentionDays: 30
    )

    static let npmCaches = CleanupRule(
        id: "npm-caches",
        name: "npm caches",
        summary: "Downloaded package cache and temporary npx installations.",
        locations: [
            home.appending(path: ".npm/_cacache", directoryHint: .isDirectory),
            home.appending(path: ".npm/_npx", directoryHint: .isDirectory)
        ],
        supportsRetention: false,
        systemImage: "shippingbox",
        caution: "npm and npx will download packages again when needed.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: ["npm", "npx", "node"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes the validated npm package cache and npx install "
                + "cache while preserving each cache root. npm and npx will re-download packages "
                + "on next use."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let swiftPMCache = CleanupRule(
        id: "swiftpm-cache",
        name: "SwiftPM cache",
        summary: "Resolved Swift package sources and artifacts that SwiftPM can re-fetch.",
        locations: [
            home.appending(
                path: "Library/Caches/org.swift.swiftpm",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: false,
        systemImage: "shippingbox",
        caution: "Close Xcode and other Swift tooling first.",
        affectedApplicationBundleIdentifiers: ["com.apple.dt.Xcode"],
        affectedApplicationNames: ["Xcode"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes the validated SwiftPM cache while preserving its "
                + "root. Swift Package Manager will re-resolve and re-download dependencies on "
                + "the next build."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let playwrightCache = CleanupRule(
        id: "playwright-cache",
        name: "Playwright cache",
        summary: "Downloaded Playwright browser binaries that Playwright can re-download.",
        locations: [
            home.appending(
                path: "Library/Caches/ms-playwright",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: false,
        systemImage: "shippingbox",
        caution: "Close any running Playwright test session first.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: ["playwright"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes the validated Playwright browser cache while "
                + "preserving its root. Playwright will re-download browser binaries the next "
                + "time a test suite runs."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let copilotCache = CleanupRule(
        id: "copilot-cache",
        name: "Copilot cache",
        summary: "Regenerable GitHub Copilot CLI and SDK caches.",
        locations: [
            home.appending(
                path: "Library/Caches/github-copilot-sdk",
                directoryHint: .isDirectory
            ),
            home.appending(
                path: "Library/Caches/copilot",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: false,
        systemImage: "shippingbox",
        caution: "Close running Copilot CLI or SDK sessions first.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: ["copilot"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes the validated Copilot CLI and SDK caches while "
                + "preserving each root. Copilot will rebuild or re-download this cache data on "
                + "its next run."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let browserCaches = CleanupRule(
        id: "browser-caches",
        name: "Browser caches",
        summary: "Regenerable Microsoft Edge and Google Chrome per-profile caches.",
        locations: [
            home.appending(
                path: "Library/Caches/Microsoft Edge",
                directoryHint: .isDirectory
            ),
            home.appending(
                path: "Library/Caches/Google/Chrome",
                directoryHint: .isDirectory
            )
        ],
        supportsRetention: false,
        systemImage: "globe",
        caution: "Quit all affected browsers before cleaning.",
        affectedApplicationBundleIdentifiers: [
            "com.microsoft.edgemac",
            "com.google.Chrome"
        ],
        affectedApplicationNames: [
            "Microsoft Edge",
            "Microsoft Edge Helper",
            "Google Chrome",
            "Google Chrome Helper"
        ],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes validated per-profile browser cache contents. "
                + "Never deletes cookies, history, sessions, saved passwords, extensions, "
                + "profile settings, or other Google application data; browsers will rebuild "
                + "cached resources as pages reload."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let appUpdaterStaging = CleanupRule(
        id: "app-updater-staging",
        name: "Stale updater downloads",
        summary: "Staging folders left behind by app self-updaters after an update finished.",
        locations: [
            home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        ],
        supportsRetention: false,
        systemImage: "arrow.down.circle",
        caution: "Quit any app that is currently installing an update.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .moveToTrash,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Moves the staging folder to Trash, so it can be recovered until Trash "
                + "is emptied. These folders hold a copy of an update the app has already "
                + "installed; the updater recreates its staging folder the next time it runs."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let userLogs = CleanupRule(
        id: "user-logs",
        name: "Old user logs",
        summary: "Application logs in your user Library that are older than the selected age.",
        locations: [
            home.appending(path: "Library/Logs", directoryHint: .isDirectory)
        ],
        supportsRetention: true,
        systemImage: "doc.text.magnifyingglass",
        caution: "Keep recent logs when diagnosing an application problem.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: [],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .moveToTrash,
            isRegenerable: false,
            requiresPrivilege: false,
            consequence: "Moves selected logs to Trash, so they can be recovered until Trash is "
                + "emptied. Unreadable or currently open log files are skipped individually "
                + "rather than failing the whole cleanup."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil,
        defaultRetentionDays: 30
    )

    static let homebrewCleanup = CleanupRule(
        id: "homebrew-cleanup",
        name: "Homebrew cleanup",
        summary: "Old package versions and downloads identified by Homebrew.",
        locations: [
            URL(filePath: "/opt/homebrew", directoryHint: .isDirectory),
            URL(filePath: "/usr/local", directoryHint: .isDirectory)
        ],
        supportsRetention: false,
        systemImage: "mug",
        caution: "SpaceMender delegates this cleanup to Homebrew’s own `brew cleanup` command.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: ["brew"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .externalCommand,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Runs Homebrew’s supported cleanup command against whichever Homebrew "
                + "installation SpaceMender discovers (Apple Silicon, Intel, or a configured "
                + "HOMEBREW_PREFIX). When Homebrew’s own estimate can’t be parsed reliably, "
                + "SpaceMender shows the reclaimable size as unknown rather than guessing."
        ),
        managedLocationDescription: "Managed through brew cleanup",
        cleanupUnavailableReason: nil
    )

    static var builtIn: [CleanupRule] {
        CleanupProviderCatalog.builtIn.rules
    }
}
