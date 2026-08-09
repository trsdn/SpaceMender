import SwiftUI

struct OverviewView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            selectionBar
            if let progress = viewModel.overviewCleanupProgress, viewModel.isCleaning {
                cleanupProgress(progress)
            } else if let report = viewModel.lastOverviewCleanupReport {
                cleanupResult(report)
            }
            providerList
        }
        .padding(24)
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.scanOverview()
                } label: {
                    Label("Scan All", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(viewModel.isScanning || viewModel.isCleaning)
                .help("Scan every cleanup provider")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overview")
                .font(.largeTitle.bold())
            Text("Review cleanup candidates across every provider. New scans select nothing.")
                .foregroundStyle(.secondary)
            if viewModel.isScanning {
                ProgressView("Scanning providers…")
                    .accessibilityLabel("Scanning all cleanup providers")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            metric(
                title: "Selected",
                value: ByteCountFormatter.string(
                    fromByteCount: viewModel.overviewSelectedBytes,
                    countStyle: .file
                )
            )
            metric(
                title: "Items",
                value: "\(viewModel.overviewSelectedItems.count) of \(viewModel.overviewItems.count)"
            )
            Spacer()
            Button("Clear") {
                viewModel.clearOverviewSelection()
            }
            .disabled(viewModel.overviewSelectedItemIDs.isEmpty || viewModel.isCleaning)
            .help("Clear all overview selections")
            Button("Select All Safe") {
                viewModel.selectAllSafe()
            }
            .disabled(viewModel.overviewSafeItemIDs.isEmpty || viewModel.isCleaning)
            .help("Select only regenerable or Trash-recoverable items without current conflicts")
            Button("Review Cleanup", role: .destructive) {
                viewModel.requestOverviewCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canCleanOverview)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private var providerList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.overviewProviders) { provider in
                    providerCard(provider)
                }
            }
        }
    }

    private func providerCard(_ provider: OverviewProviderResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(provider.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(provider.items) { item in
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.isOverviewSelected(item) },
                            set: { viewModel.setOverviewSelected($0, item: item) }
                        )
                    ) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .lineLimit(1)
                                if let notice = item.notice {
                                    Text(notice)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(size(item))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(item.displayName), \(provider.rule.name)")
                    .help(provider.rule.safety.consequence)
                    .disabled(viewModel.isCleaning || !isAvailable(provider.status))
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.isProviderSelected(provider.id) },
                        set: { viewModel.setProviderSelected($0, providerID: provider.id) }
                    )
                )
                .labelsHidden()
                .disabled(provider.items.isEmpty || viewModel.isCleaning || !isAvailable(provider.status))
                .accessibilityLabel("Select all items from \(provider.rule.name)")
                Image(systemName: provider.rule.systemImage)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.rule.name)
                        .font(.headline)
                    Text(providerSummary(provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel(provider.status)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 11))
    }

    private func providerSummary(_ provider: OverviewProviderResult) -> String {
        var parts = [
            "\(provider.items.count) item\(provider.items.count == 1 ? "" : "s")",
            ByteCountFormatter.string(fromByteCount: provider.totalBytes, countStyle: .file)
        ]
        if provider.rule.supportsRetention {
            parts.append("\(provider.retentionDays ?? provider.rule.defaultRetentionDays ?? 30)-day retention")
        } else {
            parts.append("No age filter")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLabel(_ status: OverviewProviderScanStatus) -> some View {
        switch status {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .scanning:
            ProgressView().controlSize(.small).accessibilityLabel("Scanning provider")
        case .available:
            Label("Available", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .unavailable(let reason):
            Label("Unavailable", systemImage: "lock.circle")
                .foregroundStyle(.secondary)
                .help(reason)
        case .failed(let message):
            Label("Scan failed", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func cleanupProgress(_ progress: OverviewCleanupProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(
                    value: Double(progress.completedItems),
                    total: Double(max(1, progress.totalItems))
                ) {
                    Text("Cleaning \(progress.completedItems) of \(progress.totalItems)")
                }
                .accessibilityValue("\(progress.completedItems) of \(progress.totalItems) items")
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.cancelOverviewCleanup()
                }
                .disabled(progress.isCancelling)
                .help("Stop after the current operation reaches a safe cancellation point")
            }
            if let providerID = progress.providerID,
               let provider = viewModel.overviewProviders.first(where: { $0.id == providerID }) {
                Text("Current provider: \(provider.rule.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.frozenOverviewPlan?.items ?? []) { item in
                HStack {
                    Image(systemName: progressIcon(progress.itemStates[
                        OverviewItemID(providerID: item.providerID, itemID: item.id)
                    ]))
                    Text(item.displayName)
                    Spacer()
                    Text(progressText(progress.itemStates[
                        OverviewItemID(providerID: item.providerID, itemID: item.id)
                    ]))
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cleanupResult(_ report: CrossProviderCleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                Label(
                    "\(formatted(report.permanentlyReclaimedBytes)) permanently reclaimed",
                    systemImage: "internaldrive"
                )
                Label(
                    "\(formatted(report.movedToTrashBytes)) moved to Trash",
                    systemImage: "trash"
                )
                Spacer()
                if report.movedToTrashBytes > 0 {
                    Button("Open Trash in Finder") {
                        viewModel.openTrashInFinder()
                    }
                }
            }
            ForEach(Array(report.providerReports.enumerated()), id: \.offset) { _, providerReport in
                let providerName = viewModel.rules.first {
                    $0.id == providerReport.providerID
                }?.name ?? providerReport.providerID
                Text(providerName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(providerReport.outcomes) { outcome in
                    HStack {
                        Image(systemName: outcomeIcon(outcome.status))
                        Text(outcome.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(outcome.status.rawValue)
                            .foregroundStyle(.secondary)
                        if let message = outcome.message {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(message)
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func size(_ item: CleanupItem) -> String {
        item.hasUnknownSize ? "Unknown" : formatted(item.allocatedSize)
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func isAvailable(_ status: OverviewProviderScanStatus) -> Bool {
        if case .available = status { return true }
        return false
    }

    private func progressIcon(_ state: OverviewCleanupItemState?) -> String {
        switch state {
        case .waiting, nil: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .finished(.cleaned), .finished(.movedToTrash): "checkmark.circle.fill"
        case .finished(.cancelled), .finished(.skippedChanged): "exclamationmark.circle.fill"
        case .finished(.failed): "xmark.circle.fill"
        }
    }

    private func progressText(_ state: OverviewCleanupItemState?) -> String {
        switch state {
        case .waiting, nil: "Waiting"
        case .running: "In progress"
        case .finished(let status): status.rawValue
        }
    }

    private func outcomeIcon(_ status: CleanupOutcomeStatus) -> String {
        switch status {
        case .cleaned, .movedToTrash: "checkmark.circle.fill"
        case .skippedChanged, .cancelled: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

struct OverviewConfirmationView: View {
    let plan: CrossProviderCleanupPlan
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm Cleanup")
                .font(.title.bold())
            Text("This frozen plan contains \(plan.items.count) item\(plan.items.count == 1 ? "" : "s"). Only these items will execute.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CleanupConsequenceGroup.allCases) { group in
                        if let items = plan.groupedItems[group], !items.isEmpty {
                            GroupBox(group.title) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(consequenceText(group))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(items) { item in
                                        HStack {
                                            Text(item.displayName)
                                            Spacer()
                                            Text(ByteCountFormatter.string(
                                                fromByteCount: item.allocatedSize,
                                                countStyle: .file
                                            ))
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Clean Up", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 480)
    }

    private func consequenceText(_ group: CleanupConsequenceGroup) -> String {
        switch group {
        case .trash:
            "Recoverable until Trash is emptied. These bytes are reported separately from permanent reclamation."
        case .permanentCacheDeletion:
            "Permanently deletes validated cache or diagnostic data."
        case .vendorCommand:
            "Runs the provider’s supported vendor command for exactly the selected plan."
        case .privilegedHelper:
            "Uses the fixed-operation privileged helper after independent validation."
        }
    }
}

struct CleanupHistoryView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup History")
                .font(.largeTitle.bold())
            Text("Stored locally without file paths or file contents.")
                .foregroundStyle(.secondary)
            if viewModel.cleanupHistory.isEmpty {
                ContentUnavailableView(
                    "No cleanup history",
                    systemImage: "clock",
                    description: Text("Completed cleanup attempts will appear here.")
                )
            } else {
                Table(viewModel.cleanupHistory) {
                    TableColumn("Date") { entry in
                        Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
                    }
                    TableColumn("Provider") { entry in
                        Text(entry.providerName)
                    }
                    TableColumn("Outcome") { entry in
                        Text(entry.outcome)
                    }
                    TableColumn("Permanently reclaimed") { entry in
                        Text(ByteCountFormatter.string(
                            fromByteCount: entry.permanentlyReclaimedBytes,
                            countStyle: .file
                        ))
                    }
                    TableColumn("Moved to Trash") { entry in
                        Text(ByteCountFormatter.string(
                            fromByteCount: entry.movedToTrashBytes,
                            countStyle: .file
                        ))
                    }
                }
            }
        }
        .padding(24)
    }
}
