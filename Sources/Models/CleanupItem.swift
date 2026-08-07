import Foundation

struct CleanupItem: Identifiable, Sendable {
    let id: String
    let displayName: String
    let url: URL?
    let modifiedAt: Date?
    let allocatedSize: Int64
}

struct CleanupScanResult: Sendable {
    let rule: CleanupRule
    let items: [CleanupItem]
    let scannedAt: Date

    var reclaimableBytes: Int64 {
        items.reduce(0) { $0 + $1.allocatedSize }
    }
}
