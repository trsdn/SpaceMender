import Foundation

struct CleanupHistoryEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let providerID: String
    let providerName: String
    let outcome: String
    let permanentlyReclaimedBytes: Int64
    let movedToTrashBytes: Int64
    let itemCount: Int
}

protocol CleanupHistoryStoring: Sendable {
    func load() async -> [CleanupHistoryEntry]
    func record(report: CrossProviderCleanupReport, plan: CrossProviderCleanupPlan) async
}

actor CleanupHistoryStore: CleanupHistoryStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumEntries: Int

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEntries: Int = 100
    ) {
        self.fileManager = fileManager
        self.maximumEntries = maximumEntries
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appending(path: "SpaceMender", directoryHint: .isDirectory)
            self.fileURL = directory.appending(path: "cleanup-history.json")
        }
    }

    func load() async -> [CleanupHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder.history.decode([CleanupHistoryEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    func record(report: CrossProviderCleanupReport, plan: CrossProviderCleanupPlan) async {
        var entries = await load()
        for providerReport in report.providerReports {
            guard let rule = plan.rulesByProviderID[providerReport.providerID] else {
                continue
            }
            let permanentBytes = providerReport.outcomes.reduce(Int64.zero) { total, outcome in
                guard outcome.status == .cleaned,
                      let item = providerReport.itemsByID[outcome.itemID],
                      item.cleanupPolicy != .moveToTrash else {
                    return total
                }
                return total + max(0, item.allocatedSize)
            }
            let trashBytes = providerReport.outcomes.reduce(Int64.zero) { total, outcome in
                guard outcome.status == .movedToTrash,
                      let item = providerReport.itemsByID[outcome.itemID] else {
                    return total
                }
                return total + max(0, item.allocatedSize)
            }
            let statuses = Set(providerReport.outcomes.map(\.status))
            let outcome: String
            if !statuses.isEmpty
                && statuses.isSubset(of: [.cleaned, .movedToTrash]) {
                outcome = "Succeeded"
            } else if statuses == [.cancelled] {
                outcome = "Cancelled"
            } else if statuses.contains(.cleaned) || statuses.contains(.movedToTrash) {
                outcome = "Partially succeeded"
            } else {
                outcome = "Failed"
            }
            entries.insert(
                CleanupHistoryEntry(
                    id: UUID(),
                    timestamp: report.completedAt,
                    providerID: providerReport.providerID,
                    providerName: rule.name,
                    outcome: outcome,
                    permanentlyReclaimedBytes: permanentBytes,
                    movedToTrashBytes: trashBytes,
                    itemCount: providerReport.outcomes.count
                ),
                at: 0
            )
        }

        entries = Array(entries.prefix(maximumEntries))
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.history.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is best effort and must never make cleanup fail.
        }
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
