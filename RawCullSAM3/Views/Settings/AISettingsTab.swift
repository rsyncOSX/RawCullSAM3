import SwiftUI

struct AISettingsTab: View {
    private let modelResourceManager: SAM3ModelResourceManager

    @State private var status: SAM3ModelStatus = .missing
    @State private var showDownloadPlaceholder = false

    init(modelResourceManager: SAM3ModelResourceManager = SAM3ModelResourceManager()) {
        self.modelResourceManager = modelResourceManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Models")
                        .font(.system(size: 14, weight: .semibold))
                    Divider()

                    statusRow

                    Text(status.displayMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button(
                    action: { showDownloadPlaceholder = true },
                    label: {
                        Label("Download SAM 3 Model", systemImage: "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                    },
                )
                .disabled(status.isInstalled)
                .buttonStyle(RefinedGlassButtonStyle())

                Button(
                    action: refreshStatus,
                    label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    },
                )
                .buttonStyle(RefinedGlassButtonStyle())

                Spacer()
            }

            Spacer()
        }
        .task {
            refreshStatus()
        }
        .alert("SAM 3 Model Download", isPresented: $showDownloadPlaceholder) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The SAM 3 model download location will be added later. For now, install the model files manually in \(SAM3ModelResourceManager.defaultInstalledModelDirectory().path).")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)

            Text("SAM 3 model:")
                .font(.system(size: 12, weight: .medium))

            Text(status.displayTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)

            Spacer()
        }
    }

    private var statusIconName: String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle"
        case .invalid: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .installed: .green
        case .missing: .orange
        case .invalid: .red
        }
    }

    private func refreshStatus() {
        status = modelResourceManager.modelStatus()
    }
}
