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
                "developer-caches",
                [
                    home.appending(path: "Library/Caches/org.swift.swiftpm").path,
                    home.appending(path: "Library/Caches/ms-playwright").path,
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
                ["/opt/homebrew"]
            )
        ]

        #expect(CleanupRule.builtIn.map(\.id) == expected.map(\.0))
        #expect(CleanupRule.builtIn.map { $0.locations.map(\.path) } == expected.map(\.1))
    }

    @Test
    func defenderCleanupIsExplicitlyUnavailable() {
        #expect(CleanupRule.defenderDiagnostics.cleanupPolicy == .unavailable)
        #expect(CleanupRule.defenderDiagnostics.cleanupUnavailableReason != nil)
    }

    @Test
    func cacheRulesPreserveTheirDeclaredRoots() {
        let cacheRuleIDs = ["npm-caches", "developer-caches", "browser-caches"]
        let cacheRules = CleanupRule.builtIn.filter { cacheRuleIDs.contains($0.id) }

        #expect(cacheRules.allSatisfy { $0.cleanupPolicy == .permanentDeleteContents })
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
            scanKind: .fixedLocations,
            cleanupAction: .deleteItems,
            cleanupPolicy: .permanentDeleteContents,
            supportsRetention: false,
            systemImage: "doc",
            caution: nil,
            affectedApplicationBundleIdentifiers: [],
            affectedApplicationNames: []
        )
    }
}
