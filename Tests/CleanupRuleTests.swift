import Foundation
import Testing
@testable import SpaceMender

struct CleanupRuleTests {
    @Test
    func builtInRulesPreserveSupportedCleanupRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected: [(String, [String])] = [
            (
                "microsoft-defender-diagnostics",
                ["/Library/Application Support/Microsoft/Defender/wdavdiag"]
            ),
            (
                "xcode-unavailable-simulators",
                [home.appending(path: "Library/Developer/CoreSimulator/Devices").path]
            ),
            (
                "xcode-derived-data",
                [home.appending(path: "Library/Developer/Xcode/DerivedData").path]
            ),
            (
                "npm-caches",
                [
                    home.appending(path: ".npm/_cacache").path,
                    home.appending(path: ".npm/_npx").path
                ]
            ),
            (
                "swiftpm-cache",
                [home.appending(path: "Library/Caches/org.swift.swiftpm").path]
            ),
            (
                "playwright-cache",
                [home.appending(path: "Library/Caches/ms-playwright").path]
            ),
            (
                "copilot-cache",
                [
                    home.appending(path: "Library/Caches/github-copilot-sdk").path,
                    home.appending(path: "Library/Caches/copilot").path
                ]
            ),
            (
                "browser-caches",
                [
                    home.appending(path: "Library/Caches/Microsoft Edge").path,
                    home.appending(path: "Library/Caches/Google/Chrome").path
                ]
            ),
            (
                "user-logs",
                [home.appending(path: "Library/Logs").path]
            ),
            (
                "homebrew-cleanup",
                ["/opt/homebrew", "/usr/local"]
            )
        ]

        #expect(CleanupRule.builtIn.map(\.id) == expected.map(\.0))
        #expect(CleanupRule.builtIn.map { $0.locations.map(\.path) } == expected.map(\.1))
    }

    @Test
    func defenderCleanupUsesPrivilegedDeletionButStartsExplicitlyUnavailable() {
        #expect(CleanupRule.defenderDiagnostics.cleanupPolicy == .permanentDelete)
        #expect(CleanupRule.defenderDiagnostics.cleanupUnavailableReason != nil)
    }

    @Test
    func cacheRulesPreserveTheirDeclaredRoots() {
        let cacheRuleIDs = [
            "npm-caches", "swiftpm-cache", "playwright-cache", "copilot-cache", "browser-caches"
        ]
        let cacheRules = CleanupRule.builtIn.filter { cacheRuleIDs.contains($0.id) }

        #expect(cacheRules.count == cacheRuleIDs.count)
        #expect(cacheRules.allSatisfy { $0.cleanupPolicy == .permanentDeleteContents })
        #expect(cacheRules.allSatisfy { !$0.supportsRetention && $0.defaultRetentionDays == nil })
    }

    @Test
    func developerCacheCategoriesAreDistinctProvidersWithTheirOwnConsequenceText() throws {
        let swiftPM = try #require(CleanupRule.builtIn.first { $0.id == "swiftpm-cache" })
        let playwright = try #require(CleanupRule.builtIn.first { $0.id == "playwright-cache" })
        let copilot = try #require(CleanupRule.builtIn.first { $0.id == "copilot-cache" })

        let consequences = [swiftPM, playwright, copilot].map(\.safety.consequence)
        #expect(Set(consequences).count == 3, "Each developer cache category must have distinct consequence text")
        #expect(swiftPM.safety.consequence.localizedCaseInsensitiveContains("SwiftPM") == true)
        #expect(playwright.safety.consequence.localizedCaseInsensitiveContains("Playwright") == true)
        #expect(copilot.safety.consequence.localizedCaseInsensitiveContains("Copilot") == true)
    }

    @Test
    func everyBuiltInRuleDeclaresNonEmptyDistinctConsequenceText() {
        let rules = CleanupRule.builtIn
        let consequences = rules.map(\.safety.consequence)

        #expect(consequences.allSatisfy { !$0.isEmpty })
        #expect(Set(consequences).count == consequences.count, "Consequence text must be distinct per provider")
    }

    @Test
    func retentionSupportExactlyMatchesDeclaredDefaultRetentionDays() {
        for rule in CleanupRule.builtIn {
            #expect(
                rule.supportsRetention == (rule.defaultRetentionDays != nil),
                "\(rule.id) must declare a default retention age if and only if it supports retention"
            )
        }
    }

    @Test
    func defenderDerivedDataAndUserLogsDefaultToThirtyDayRetention() {
        let retentionRuleIDs = ["microsoft-defender-diagnostics", "xcode-derived-data", "user-logs"]
        let retentionRules = CleanupRule.builtIn.filter { retentionRuleIDs.contains($0.id) }

        #expect(retentionRules.count == retentionRuleIDs.count)
        #expect(retentionRules.allSatisfy { $0.defaultRetentionDays == 30 })
    }

    @Test
    func homebrewDiscoversAppleSiliconIntelAndConfiguredLocations() throws {
        let homebrew = try #require(CleanupRule.builtIn.first { $0.id == "homebrew-cleanup" })

        #expect(homebrew.locations.map(\.path).contains("/opt/homebrew"))
        #expect(homebrew.locations.map(\.path).contains("/usr/local"))
    }

    @Test
    func containsAcceptsRootsAndDescendantsButRejectsSiblingPrefixes() {
        let root = URL(filePath: "/tmp/SpaceMender/cache", directoryHint: .isDirectory)
        let rule = makeRule(location: root)

        #expect(rule.contains(root))
        #expect(rule.contains(root.appending(path: "nested/item.data")))
        #expect(!rule.contains(URL(filePath: "/tmp/SpaceMender/cache-other/item.data")))
        #expect(!rule.contains(URL(filePath: "/tmp/SpaceMender/elsewhere/item.data")))
    }

    private func makeRule(location: URL) -> CleanupRule {
        CleanupRule(
            id: "test",
            name: "Test",
            summary: "Test rule",
            locations: [location],
            supportsRetention: false,
            systemImage: "doc",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: [],
            safety: CleanupSafetyMetadata(
                cleanupPolicy: .permanentDeleteContents,
                isRegenerable: true,
                requiresPrivilege: false,
                consequence: "Test cleanup"
            ),
            managedLocationDescription: nil,
            cleanupUnavailableReason: nil
        )
    }
}
