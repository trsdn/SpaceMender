import Testing
@testable import SpaceMender

struct OverviewViewAccessibilityTests {
    @Test
    func itemAccessibilityLabelsPreserveActionItemAndProviderContext() {
        #expect(
            OverviewAccessibility.itemSelectionLabel(
                itemName: "Default",
                providerName: "Browser caches"
            ) == "Select Default in Browser caches"
        )
    }

    @Test
    func overviewAccessibilityCopyRemainsSpecificToBulkSelectionAndScanning() {
        #expect(OverviewAccessibility.scanningAllProviders == "Scanning all cleanup providers")
        #expect(OverviewAccessibility.scanningProvider == "Scanning provider")
        #expect(
            OverviewAccessibility.selectAllItemsLabel(providerName: "Copilot cache")
                == "Select all items from Copilot cache"
        )
    }
}
