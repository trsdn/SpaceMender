import AppKit
import SwiftUI

enum OverviewAccessibility {
    static let scanningAllProviders = "Scanning all cleanup providers"
    static let scanningProvider = "Scanning provider"

    static func itemSelectionLabel(itemName: String, providerName: String) -> String {
        "Select \(itemName) in \(providerName)"
    }

    static func selectAllItemsLabel(providerName: String) -> String {
        "Select all items from \(providerName)"
    }
}

struct OverviewView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                .keyboardShortcut("r", modifiers: .command)
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
                    .accessibilityLabel(OverviewAccessibility.scanningAllProviders)
                    .accessibilityValue("In progress")
            }
        }
    }

    private var selectionBar: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
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
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Button("Clear") {
                viewModel.clearOverviewSelection()
            }
            .disabled(viewModel.overviewSelectedItemIDs.isEmpty || viewModel.isCleaning)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Clear all overview selections")
            .accessibilityLabel("Clear overview selection")
            .accessibilityValue("\(viewModel.overviewSelectedItems.count) selected")
            Button("Select All Safe") {
                viewModel.selectAllSafe()
            }
            .disabled(viewModel.overviewSafeItemIDs.isEmpty || viewModel.isCleaning)
            .keyboardShortcut("a", modifiers: .command)
            .help("Select only regenerable or Trash-recoverable items without current conflicts")
            .accessibilityLabel("Select all safe items")
            .accessibilityValue("\(viewModel.overviewSafeItemIDs.count) available")
            Button("Review Cleanup", role: .destructive) {
                viewModel.requestOverviewCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .help(viewModel.canCleanOverview ? "Review the selected items before cleanup" : "Select one or more available items first")
            .accessibilityLabel("Review cleanup")
            .accessibilityValue("\(viewModel.overviewSelectedItems.count) selected")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
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
                        .foregroundStyle(.primary)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Warning: \(warning)")
                        .accessibilityHint("Resolve this warning before cleanup")
                }
                if let details = provider.technicalDetails, !details.isEmpty {
                    Button("Copy Technical Details") {
                        copy(details)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Copy technical details for \(provider.rule.name)")
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
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
                    .accessibilityLabel(
                        OverviewAccessibility.itemSelectionLabel(
                            itemName: item.displayName,
                            providerName: provider.rule.name
                        )
                    )
                    .accessibilityValue(viewModel.isOverviewSelected(item) ? "Selected" : "Not selected")
                    .accessibilityHint("\(provider.rule.safety.consequence) Size: \(size(item)).")
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
                .accessibilityLabel(
                    OverviewAccessibility.selectAllItemsLabel(providerName: provider.rule.name)
                )
                .accessibilityValue(viewModel.isProviderSelected(provider.id) ? "All selected" : "Not all selected")
                .accessibilityHint("Selects or clears every available item in this category")
                Image(systemName: provider.rule.systemImage)
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.rule.name), \(providerSummary(provider)), \(statusText(provider.status))")
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 11))
    }

    private func providerSummary(_ provider: OverviewProviderResult) -> String {
        let count = provider.items.count
        var parts = [
            count == 1 ? String(localized: "1 item") : String(localized: "\(count) items"),
            ByteCountFormatter.string(fromByteCount: provider.totalBytes, countStyle: .file)
        ]
        if provider.rule.supportsRetention {
            let days = provider.retentionDays ?? provider.rule.defaultRetentionDays ?? 30
            parts.append(String(localized: "\(days)-day retention"))
        } else {
            parts.append(String(localized: "No age filter"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLabel(_ status: OverviewProviderScanStatus) -> some View {
        switch status {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .scanning:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(OverviewAccessibility.scanningProvider)
                .accessibilityValue("In progress")
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
                .accessibilityLabel("Scan failed")
                .accessibilityHint(message)
        }
    }

    private func statusText(_ status: OverviewProviderScanStatus) -> String {
        switch status {
        case .waiting: String(localized: "Waiting")
        case .scanning: String(localized: "Scanning")
        case .available: String(localized: "Available")
        case .unavailable(let reason): String(localized: "Unavailable: \(reason)")
        case .failed(let message): String(localized: "Scan failed: \(message)")
        }
    }

    private func progressAccessibilityValue(_ progress: OverviewCleanupProgress) -> String {
        let total = progress.totalItems == 1
            ? String(localized: "1 item")
            : String(localized: "\(progress.totalItems) items")
        return String(localized: "\(progress.completedItems) of \(total) completed")
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
                .accessibilityLabel("Cleanup progress")
                .accessibilityValue(progressAccessibilityValue(progress))
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.cancelOverviewCleanup()
                }
                .disabled(progress.isCancelling)
                .keyboardShortcut(.cancelAction)
                .help("Stop after the current operation reaches a safe cancellation point")
                .accessibilityLabel("Cancel cleanup")
                .accessibilityHint("Stops after the current operation reaches a safe cancellation point")
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
                    .accessibilityHidden(true)
                    Text(item.displayName)
                    Spacer()
                    Text(progressText(progress.itemStates[
                        OverviewItemID(providerID: item.providerID, itemID: item.id)
                    ]))
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.displayName): \(progressText(progress.itemStates[OverviewItemID(providerID: item.providerID, itemID: item.id)]))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cleanup progress")
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
                            .accessibilityHidden(true)
                        Text(outcome.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(outcomeText(outcome.status))
                            .foregroundStyle(.secondary)
                        if let message = outcome.message {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(message)
                        }
                        if let details = outcome.technicalDetails, !details.isEmpty {
                            Button("Copy Details") {
                                copy(details)
                            }
                            .buttonStyle(.link)
                            .accessibilityLabel("Copy technical details for \(outcome.displayName)")
                        }
                    }
                    .font(.caption)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(outcome.displayName): \(outcomeText(outcome.status))")
                    .accessibilityHint(outcome.message ?? "")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cleanup results")
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copy(_ details: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
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
        case .waiting, nil: String(localized: "Waiting")
        case .running: String(localized: "In progress")
        case .finished(let status): outcomeText(status)
        }
    }

    private func outcomeText(_ status: CleanupOutcomeStatus) -> String {
        switch status {
        case .cleaned: String(localized: "Cleaned")
        case .movedToTrash: String(localized: "Moved to Trash")
        case .skippedChanged: String(localized: "Skipped — changed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
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
            Text(confirmationSummary)
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
                    .keyboardShortcut(.cancelAction)
                Button("Clean Up", role: .destructive, action: confirm)
                    .accessibilityLabel("Confirm destructive cleanup")
                    .accessibilityHint("Cleans only the items listed in this frozen plan")
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(idealWidth: 620, idealHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm cleanup")
    }

    private var confirmationSummary: String {
        let count = plan.items.count
        let itemCount = count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
        return String(localized: "This frozen plan contains \(itemCount). Only these items will be cleaned.")
    }

    private func consequenceText(_ group: CleanupConsequenceGroup) -> String {
        switch group {
        case .trash:
            String(localized: "Recoverable until Trash is emptied. These bytes are reported separately from permanent reclamation.")
        case .permanentCacheDeletion:
            String(localized: "Permanently deletes validated cache or diagnostic data.")
        case .vendorCommand:
            String(localized: "Runs the provider’s supported vendor command for exactly the selected plan.")
        case .privilegedHelper:
            String(localized: "Uses the fixed-operation privileged helper after independent validation.")
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
                            .accessibilityLabel("Cleanup date \(entry.timestamp.formatted(date: .long, time: .shortened))")
                    }
                    TableColumn("Provider") { entry in
                        Text(entry.providerName)
                            .accessibilityLabel("Provider \(entry.providerName)")
                    }
                    TableColumn("Outcome") { entry in
                        Text(entry.outcome)
                            .accessibilityLabel("Outcome \(entry.outcome)")
                    }
                    TableColumn("Permanently reclaimed") { entry in
                        Text(ByteCountFormatter.string(
                            fromByteCount: entry.permanentlyReclaimedBytes,
                            countStyle: .file
                        ))
                        .accessibilityLabel("Permanently reclaimed \(ByteCountFormatter.string(fromByteCount: entry.permanentlyReclaimedBytes, countStyle: .file))")
                    }
                    TableColumn("Moved to Trash") { entry in
                        Text(ByteCountFormatter.string(
                            fromByteCount: entry.movedToTrashBytes,
                            countStyle: .file
                        ))
                        .accessibilityLabel("Moved to Trash \(ByteCountFormatter.string(fromByteCount: entry.movedToTrashBytes, countStyle: .file))")
                    }
                }
            }
        }
        .padding(24)
    }
}
