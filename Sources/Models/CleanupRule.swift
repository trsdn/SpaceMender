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
            cleanupUnavailableReason: reason
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
            "Cleanup is scan-only until SpaceMender’s signed privileged helper is installed."
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
            consequence: "Deletes only the selected unavailable simulator devices through simctl."
        ),
        managedLocationDescription: "Managed through xcrun simctl",
        cleanupUnavailableReason: nil
    )

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
            consequence: "Permanently deletes regenerable build products and indexes."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
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
            consequence: "Permanently deletes validated cache contents while preserving each root."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let developerCaches = CleanupRule(
        id: "developer-caches",
        name: "Developer caches",
        summary: "Regenerable SwiftPM, Playwright, and Copilot caches.",
        locations: [
            home.appending(
                path: "Library/Caches/org.swift.swiftpm",
                directoryHint: .isDirectory
            ),
            home.appending(
                path: "Library/Caches/ms-playwright",
                directoryHint: .isDirectory
            ),
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
        systemImage: "chevron.left.forwardslash.chevron.right",
        caution: "Close developer tools first. Dependencies and browsers may be downloaded again.",
        affectedApplicationBundleIdentifiers: [
            "com.microsoft.VSCode",
            "com.github.wez.wezterm"
        ],
        affectedApplicationNames: ["Code", "playwright", "copilot"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .permanentDeleteContents,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Permanently deletes validated cache contents while preserving each root."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let browserCaches = CleanupRule(
        id: "browser-caches",
        name: "Browser caches",
        summary: "Regenerable Microsoft Edge and Google browser caches.",
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
            consequence: "Permanently deletes validated browser cache contents."
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
            consequence: "Moves selected logs to Trash."
        ),
        managedLocationDescription: nil,
        cleanupUnavailableReason: nil
    )

    static let homebrewCleanup = CleanupRule(
        id: "homebrew-cleanup",
        name: "Homebrew cleanup",
        summary: "Old package versions and downloads identified by Homebrew.",
        locations: [
            URL(filePath: "/opt/homebrew", directoryHint: .isDirectory)
        ],
        supportsRetention: false,
        systemImage: "mug",
        caution: "SpaceMender delegates this cleanup to Homebrew.",
        affectedApplicationBundleIdentifiers: [],
        affectedApplicationNames: ["brew"],
        safety: CleanupSafetyMetadata(
            cleanupPolicy: .externalCommand,
            isRegenerable: true,
            requiresPrivilege: false,
            consequence: "Runs Homebrew’s supported cleanup command."
        ),
        managedLocationDescription: "Managed through brew cleanup",
        cleanupUnavailableReason: nil
    )

    static var builtIn: [CleanupRule] {
        CleanupProviderCatalog.builtIn.rules
    }
}
