import Foundation

enum CleanupPolicy: String, Sendable {
    case unavailable
    case permanentDelete
    case permanentDeleteContents
    case moveToTrash
    case deleteSimulator
    case externalCommand
}

struct CleanupItem: Identifiable, Sendable {
    let id: String
    let providerID: String
    let stableIdentity: String
    let displayName: String
    let url: URL?
    let discoveredAt: Date
    let modifiedAt: Date?
    let resourceIdentifier: String?
    let allocatedSize: Int64
    let cleanupPolicy: CleanupPolicy
}

enum CleanupOutcomeStatus: String, Sendable {
    case cleaned
    case movedToTrash
    case skippedChanged
    case failed
    case cancelled
}

struct CleanupItemOutcome: Identifiable, Sendable {
    let itemID: String
    let displayName: String
    let status: CleanupOutcomeStatus
    let message: String?

    var id: String {
        itemID
    }
}

struct CleanupReport: Sendable {
    let outcomes: [CleanupItemOutcome]

    var hasFailures: Bool {
        outcomes.contains { $0.status == .failed }
    }
}

struct CleanupScanResult: Sendable {
    let rule: CleanupRule
    let items: [CleanupItem]
    let scannedAt: Date

    var reclaimableBytes: Int64 {
        items.reduce(0) { $0 + $1.allocatedSize }
    }
}
