import Foundation

struct OverviewItemID: Hashable, Sendable {
    let providerID: String
    let itemID: String
}

enum OverviewProviderScanStatus: Sendable, Equatable {
    case waiting
    case scanning
    case available
    case unavailable(String)
    case failed(String)
}

struct OverviewProviderResult: Identifiable, Sendable {
    let rule: CleanupRule
    let items: [CleanupItem]
    let scannedAt: Date?
    let status: OverviewProviderScanStatus
    let warnings: [String]
    let safeItemIDs: Set<OverviewItemID>
    var retentionDays: Int? = nil

    var id: String { rule.id }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.allocatedSize) }
    }
}

struct OverviewScanSnapshot: Sendable {
    let providers: [OverviewProviderResult]
    let startedAt: Date
    let completedAt: Date
}

enum CleanupConsequenceGroup: String, CaseIterable, Sendable, Identifiable {
    case trash
    case permanentCacheDeletion
    case vendorCommand
    case privilegedHelper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanentCacheDeletion: "Permanent cache deletion"
        case .vendorCommand: "Vendor command"
        case .privilegedHelper: "Privileged helper"
        }
    }
}

struct CrossProviderCleanupPlan: Sendable {
    let providerPlans: [CleanupExecutionPlan]
    let rulesByProviderID: [String: CleanupRule]
    let createdAt: Date

    var items: [CleanupItem] {
        providerPlans.flatMap(\.items)
    }

    var groupedItems: [CleanupConsequenceGroup: [CleanupItem]] {
        Dictionary(grouping: items) { item in
            let rule = rulesByProviderID[item.providerID]
            if rule?.safety.requiresPrivilege == true {
                return .privilegedHelper
            }
            switch item.cleanupPolicy {
            case .moveToTrash:
                return .trash
            case .externalCommand, .deleteSimulator:
                return .vendorCommand
            case .permanentDelete, .permanentDeleteContents, .unavailable:
                return .permanentCacheDeletion
            }
        }
    }
}

enum OverviewCleanupItemState: Sendable, Equatable {
    case waiting
    case running
    case finished(CleanupOutcomeStatus)
}

struct OverviewCleanupProgress: Sendable {
    let providerID: String?
    let itemStates: [OverviewItemID: OverviewCleanupItemState]
    let completedItems: Int
    let totalItems: Int
    let isCancelling: Bool
}

struct ProviderCleanupReport: Sendable {
    let providerID: String
    let outcomes: [CleanupItemOutcome]
    let itemsByID: [String: CleanupItem]
}

struct CrossProviderCleanupReport: Sendable {
    let providerReports: [ProviderCleanupReport]
    let startedAt: Date
    let completedAt: Date

    var outcomes: [CleanupItemOutcome] {
        providerReports.flatMap(\.outcomes)
    }

    var permanentlyReclaimedBytes: Int64 {
        providerReports.reduce(0) { total, report in
            total + report.outcomes.reduce(0) { subtotal, outcome in
                guard outcome.status == .cleaned,
                      let item = report.itemsByID[outcome.itemID],
                      item.cleanupPolicy != .moveToTrash else {
                    return subtotal
                }
                return subtotal + max(0, item.allocatedSize)
            }
        }
    }

    var movedToTrashBytes: Int64 {
        providerReports.reduce(0) { total, report in
            total + report.outcomes.reduce(0) { subtotal, outcome in
                guard outcome.status == .movedToTrash,
                      let item = report.itemsByID[outcome.itemID] else {
                    return subtotal
                }
                return subtotal + max(0, item.allocatedSize)
            }
        }
    }

    var hasFailures: Bool {
        outcomes.contains { $0.status == .failed }
    }
}
