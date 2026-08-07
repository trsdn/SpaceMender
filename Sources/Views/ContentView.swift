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
            controls
            summary
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
        }
    }

    @ViewBuilder
    private var controls: some View {
        if viewModel.selectedRule.supportsRetention {
            HStack {
                Text("Remove items older than")
                    .fontWeight(.medium)
                Picker("Retention", selection: $viewModel.retentionDays) {
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
            Button("Clean Selected", role: .destructive) {
                viewModel.requestCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(!viewModel.canClean)
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
                TableColumn("Disk space") { item in
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: item.allocatedSize,
                            countStyle: .file
                        )
                    )
                }
                .width(100)
                }
            }
        }
    }

    private var cleanupConfirmationSuffix: String {
        var suffix = "."
        if viewModel.selectedRule.requiresAdministrator {
            suffix += " macOS will request administrator approval."
        }
        if let caution = viewModel.selectedRule.caution {
            suffix += " \(caution)"
        }
        return suffix
    }

    private var emptyDescription: String {
        if viewModel.selectedRule.supportsRetention {
            return "No matching items are older than \(viewModel.retentionDays) days."
        }
        return "No reclaimable items were found."
    }
}
