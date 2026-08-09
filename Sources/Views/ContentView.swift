import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            viewModel.scan()
        }
        .alert("Clean up \(viewModel.selectedRule.name)?", isPresented: $viewModel.showingCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Up", role: .destructive) {
                viewModel.performCleanup()
            }
        } message: {
            Text(
                "SpaceMender will clean \(viewModel.selectedItems.count) selected item(s) and reclaim approximately "
                    + ByteCountFormatter.string(
                        fromByteCount: viewModel.selectedBytes,
                        countStyle: .file
                    )
                    + cleanupConfirmationSuffix
            )
        }
        .alert(
            "SpaceMender couldn’t complete the operation",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { viewModel.selectedRule.id },
            set: { id in
                guard let rule = viewModel.rules.first(where: { $0.id == id }) else {
                    return
                }
                viewModel.selectedRule = rule
                viewModel.scan()
            }
        )) {
            Section("Cleanup locations") {
                ForEach(viewModel.rules) { rule in
                    Label(rule.name, systemImage: rule.systemImage)
                        .tag(rule.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
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
                    .foregroundStyle(.orange)
            }
            if let reason = viewModel.selectedRule.cleanupUnavailableReason {
                Label(reason, systemImage: "lock.shield")
                    .font(.callout)
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
                .onChange(of: viewModel.retentionDays) {
                    viewModel.scan()
                }
                Spacer()
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
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
            Spacer()
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
                            .foregroundStyle(outcomeColor(outcome.status))
                        Text(outcome.displayName)
                            .lineLimit(1)
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
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
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
                    }
                    .width(28)
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

    private var cleanupConfirmationSuffix: String {
        var suffix = "."
        if let caution = viewModel.selectedRule.caution {
            suffix += " \(caution)"
        }
        return suffix
    }

    private func outcomeLabel(_ status: CleanupOutcomeStatus) -> String {
        switch status {
        case .cleaned: "Cleaned"
        case .movedToTrash: "Moved to Trash"
        case .skippedChanged: "Skipped — changed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
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
            return "No matching items are older than \(viewModel.retentionDays) days."
        }
        return "No reclaimable items were found."
    }
}
