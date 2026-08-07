import Foundation
import Testing
@testable import SpaceMender

@MainActor
struct AppViewModelTests {
    @Test
    func newResultsStartWithNothingSelected() {
        let viewModel = AppViewModel(result: makeResult())

        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(viewModel.selectedItems.isEmpty)
        #expect(!viewModel.canClean)
    }

    @Test
    func individualSelectionIncludesOnlyRequestedItems() {
        let result = makeResult()
        let viewModel = AppViewModel(result: result)

        viewModel.setSelected(true, item: result.items[1])

        #expect(viewModel.selectedItemIDs == [result.items[1].id])
        #expect(viewModel.selectedItems.map(\.id) == [result.items[1].id])
        #expect(viewModel.selectedBytes == result.items[1].allocatedSize)
        #expect(viewModel.canClean)

        viewModel.setSelected(false, item: result.items[1])

        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test
    func selectAllAndClearSelectionTrackCurrentItems() {
        let result = makeResult()
        let viewModel = AppViewModel(result: result)

        viewModel.selectAll()

        #expect(viewModel.selectedItemIDs == Set(result.items.map(\.id)))
        #expect(viewModel.allItemsSelected)

        viewModel.clearSelection()

        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(!viewModel.allItemsSelected)
    }

    private func makeResult() -> CleanupScanResult {
        CleanupScanResult(
            rule: .xcodeDerivedData,
            items: [
                CleanupItem(
                    id: "first",
                    displayName: "First",
                    url: URL(filePath: "/tmp/first"),
                    modifiedAt: nil,
                    allocatedSize: 100
                ),
                CleanupItem(
                    id: "second",
                    displayName: "Second",
                    url: URL(filePath: "/tmp/second"),
                    modifiedAt: nil,
                    allocatedSize: 200
                )
            ],
            scannedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
