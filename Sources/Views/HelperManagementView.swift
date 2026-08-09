import ServiceManagement
import SwiftUI

struct HelperManagementView: View {
    @State private var status = SMAppService.Status.notRegistered
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let manager = DefenderHelperServiceManager()

    var body: some View {
        Form {
            Section("Microsoft Defender helper") {
                LabeledContent("Status", value: statusDescription)

                Text(
                    "The signed helper is used only to remove validated, root-owned "
                        + "Microsoft Defender diagnostic ZIP archives."
                )
                .foregroundStyle(.secondary)

                HStack {
                    Button(status == .enabled ? "Upgrade Helper" : "Install Helper") {
                        installOrUpgrade()
                    }
                    .disabled(isWorking)

                    Button("Remove Helper", role: .destructive) {
                        remove()
                    }
                    .disabled(isWorking || status == .notRegistered || status == .notFound)

                    Button("Refresh") {
                        refresh()
                    }
                    .disabled(isWorking)
                }

                if status == .requiresApproval {
                    Text("Approve SpaceMender in System Settings → General → Login Items.")
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 240)
        .task {
            refresh()
        }
    }

    private var statusDescription: String {
        switch status {
        case .enabled:
            "Installed and enabled"
        case .requiresApproval:
            "Waiting for approval"
        case .notRegistered:
            "Not installed"
        case .notFound:
            "Not found in this app"
        @unknown default:
            "Unknown"
        }
    }

    private func refresh() {
        status = manager.status
    }

    private func installOrUpgrade() {
        isWorking = true
        errorMessage = nil
        do {
            try manager.installOrUpgrade()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func remove() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await manager.remove()
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
