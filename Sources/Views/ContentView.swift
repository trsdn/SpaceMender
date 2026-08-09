import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            destinationDetail
        }
        .task {
            viewModel.scanOverview()
            viewModel.loadHistory()
        }
        .alert("Clean up \(viewModel.selectedRule.name)?", isPresented: $viewModel.showingCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Up", role: .destructive) {
                viewModel.performCleanup()
            }
        } message: {
Text(cleanupConfirmationMessage)
        }
        .alert(
            "SpaceMender couldn’t complete the operation",
            isPresented: Binding(
                get: { viewModel.presentedError != nil },
                set: { if !$0 { viewModel.presentedError = nil } }
            )
        ) {
            if viewModel.presentedError?.technicalDetails?.isEmpty == false {
                Button("Copy Technical Details") {
                    copyTechnicalDetails()
                }
            }
            Button("OK") {
                viewModel.presentedError = nil
            }
        } message: {
            Text(viewModel.presentedError?.alertMessage ?? "")
        }
        .sheet(isPresented: $viewModel.showingOverviewConfirmation) {
            if let plan = viewModel.frozenOverviewPlan {
                OverviewConfirmationView(
                    plan: plan,
                    cancel: { viewModel.showingOverviewConfirmation = false },
                    confirm: viewModel.performOverviewCleanup
                )
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { viewModel.destination },
            set: { destination in
                viewModel.destination = destination
                switch destination {
                case .overview:
                    if viewModel.overviewProviders.allSatisfy({ $0.scannedAt == nil }) {
                        viewModel.scanOverview()
                    }
                case .provider(let id):
                    guard let rule = viewModel.rules.first(where: { $0.id == id }) else {
                        return
                    }
                    viewModel.selectedRule = rule
                    viewModel.scan()
                case .history:
                    viewModel.loadHistory()
                }
            }
        )) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarDestination.overview)
            }
            Section("Cleanup locations") {
                ForEach(viewModel.rules) { rule in
                    Label(rule.name, systemImage: rule.systemImage)
                        .tag(SidebarDestination.provider(rule.id))
                }
            }
            Section {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarDestination.history)
            }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
    }

    @ViewBuilder
    private var destinationDetail: some View {
        switch viewModel.destination {
        case .overview:
            OverviewView(viewModel: viewModel)
        case .provider:
            detail
        case .history:
            CleanupHistoryView(viewModel: viewModel)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            defenderHealthBanner
            controls
            summary
            cleanupResults
            candidates
        }
        .padding(24)
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.scan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan this cleanup category")
                .accessibilityLabel("Scan \(viewModel.selectedRule.name)")
                .disabled(viewModel.isScanning || viewModel.isCleaning)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.selectedRule.name)
                .font(.largeTitle.bold())
            Text(viewModel.selectedRule.summary)
                .foregroundStyle(.secondary)
            Text(viewModel.selectedRule.locationDescription)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let caution = viewModel.selectedRule.caution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: \(caution)")
                    .accessibilityHint("Review this warning before selecting items for cleanup")
            }
            if let reason = viewModel.selectedRule.cleanupUnavailableReason {
                Label(reason, systemImage: "lock.shield")
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Cleanup unavailable: \(reason)")
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Shown only for the Defender rule and always sourced from
    /// `viewModel.defenderHealth`, a value that scanning and cleanup never
    /// write. This keeps "the diagnostic archive cleanup succeeded" and
    /// "Defender's real-time protection is healthy" visibly separate so
    /// one is never mistaken for the other.
    @ViewBuilder
    private var defenderHealthBanner: some View {
        if viewModel.selectedRule.id == CleanupRule.defenderDiagnostics.id,
           let health = viewModel.defenderHealth {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: defenderHealthIcon(health))
                    .foregroundStyle(defenderHealthColor(health))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Defender health (separate from archive cleanup)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(defenderHealthMessage(health))
                        .font(.callout)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Defender health: \(defenderHealthMessage(health)). Separate from archive cleanup.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if viewModel.selectedRule.supportsRetention {
            HStack {
                Text("Remove items older than")
                    .fontWeight(.medium)
                Picker(
                    "Retention",
                    selection: Binding(
                        get: { viewModel.retentionDays },
                        set: { viewModel.retentionDays = $0 }
                    )
                ) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                .accessibilityLabel("Cleanup age")
                .accessibilityValue("Items older than \(viewModel.retentionDays) days")
                .accessibilityHint("Changing the age scans this category again")
                .onChange(of: viewModel.retentionDays) {
                    viewModel.scan()
                }
                Spacer()
            }
        }
    }

    private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            metric(
                title: "Selected",
                value: ByteCountFormatter.string(
                    fromByteCount: viewModel.selectedBytes,
                    countStyle: .file
                ),
                icon: "internaldrive"
            )
            metric(
                title: "Selected items",
                value: "\(viewModel.selectedItems.count) of \(viewModel.items.count)",
                icon: "doc.on.doc"
            )
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Button(
                viewModel.selectedRule.cleanupUnavailableReason == nil
                    ? "Clean Selected"
                    : "Cleanup Unavailable",
                role: .destructive
            ) {
                viewModel.requestCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help(viewModel.canClean ? "Review and clean the selected items" : "Select one or more available items first")
            .accessibilityLabel("Clean selected items")
            .accessibilityValue("\(viewModel.selectedItems.count) selected")
            .disabled(!viewModel.canClean)
        }
    }

    @ViewBuilder
    private var cleanupResults: some View {
        if let report = viewModel.lastCleanupReport, !report.outcomes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last cleanup attempt")
                    .font(.headline)
                ForEach(report.outcomes) { outcome in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: outcomeIcon(outcome.status))
                            .accessibilityHidden(true)
                            .foregroundStyle(outcomeColor(outcome.status))
                        Text(outcome.displayName)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        Spacer()
                        Text(outcomeLabel(outcome.status))
                            .foregroundStyle(.secondary)
                        if let message = outcome.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
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
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(outcome.displayName): \(outcomeLabel(outcome.status))")
                    .accessibilityHint(outcome.message ?? "")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Last cleanup results")
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var candidates: some View {
        if viewModel.isScanning {
            Spacer()
            HStack {
                Spacer()
                ProgressView("Scanning…")
                    .accessibilityLabel("Scanning \(viewModel.selectedRule.name)")
                    .accessibilityValue("In progress")
                Spacer()
            }
            Spacer()
        } else if viewModel.items.isEmpty {
            ContentUnavailableView(
                "Nothing to clean",
                systemImage: "checkmark.circle",
                description: Text(emptyDescription)
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: viewModel.reclaimableBytes,
                            countStyle: .file
                        )
                        + " available"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(viewModel.allItemsSelected ? "Clear" : "Select All") {
                        if viewModel.allItemsSelected {
                            viewModel.clearSelection()
                        } else {
                            viewModel.selectAll()
                        }
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    .help(viewModel.allItemsSelected ? "Clear all item selections" : "Select all items in this category")
                }

                Table(viewModel.items) {
                    TableColumn("") { item in
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.isSelected(item) },
                                set: { viewModel.setSelected($0, item: item) }
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel("Select \(item.displayName)")
                        .accessibilityValue(viewModel.isSelected(item) ? "Selected" : "Not selected")
                        .accessibilityHint("Includes or excludes this item from cleanup")
                    }
                    .width(36)
                TableColumn("Item") { item in
                    Text(item.displayName)
                        .lineLimit(1)
                }
                TableColumn("Modified") { item in
                    if let modifiedAt = item.modifiedAt {
                        Text(modifiedAt, format: .dateTime.year().month().day())
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(110)
                TableColumn("Origin") { item in
                    Text(item.originatingApplication ?? "—")
                        .foregroundStyle(item.originatingApplication == nil ? .tertiary : .primary)
                        .lineLimit(1)
                }
                .width(120)
                TableColumn("Disk space") { item in
                    if item.hasUnknownSize {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                            .help(item.notice ?? "The reclaimable size could not be determined reliably.")
                    } else {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: item.allocatedSize,
                                countStyle: .file
                            )
                        )
                        .help(item.notice ?? "")
                    }
                }
                .width(100)
                }
            }
        }
    }

    private var cleanupConfirmationMessage: String {
        let count = viewModel.selectedItems.count
        let itemCount = count == 1
            ? String(localized: "1 selected item")
            : String(localized: "\(count) selected items")
        let size = ByteCountFormatter.string(fromByteCount: viewModel.selectedBytes, countStyle: .file)
        var message = String(localized: "SpaceMender will clean \(itemCount) and reclaim approximately \(size).")
        if let caution = viewModel.selectedRule.caution {
            message += " " + caution
        }
        return message
    }

    private func copyTechnicalDetails() {
        guard let details = viewModel.presentedError?.technicalDetails else { return }
        copy(details)
    }

    private func copy(_ details: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    private func outcomeLabel(_ status: CleanupOutcomeStatus) -> String {
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

    private func outcomeColor(_ status: CleanupOutcomeStatus) -> Color {
        switch status {
        case .cleaned, .movedToTrash: .green
        case .skippedChanged, .cancelled: .orange
        case .failed: .red
        }
    }

    private func defenderHealthMessage(_ health: DefenderHealthStatus) -> String {
        switch health {
        case .healthy:
            "Healthy"
        case .attentionNeeded(let message), .unknown(let message):
            message
        }
    }

    private func defenderHealthIcon(_ health: DefenderHealthStatus) -> String {
        switch health {
        case .healthy: "checkmark.shield"
        case .attentionNeeded: "exclamationmark.shield"
        case .unknown: "shield.slash"
        }
    }

    private func defenderHealthColor(_ health: DefenderHealthStatus) -> Color {
        switch health {
        case .healthy: .green
        case .attentionNeeded: .orange
        case .unknown: .secondary
        }
    }

    private var emptyDescription: String {
        if viewModel.selectedRule.supportsRetention {
            return String(localized: "No matching items are older than \(viewModel.retentionDays) days.")
        }
        return String(localized: "No reclaimable items were found.")
    }
}
