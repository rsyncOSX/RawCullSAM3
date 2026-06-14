import SwiftUI

struct AISettingsTab: View {
    private let sam3ModelResourceManager: SAM3ModelResourceManager
    private let clipModelResourceManager: CLIPModelResourceManager
    private var settingsManager: SettingsViewModel {
        SettingsViewModel.shared
    }

    @State private var sam3Status: SAM3ModelStatus = .missing
    @State private var clipStatus: CLIPModelStatus = .missing
    @State private var showDownloadPlaceholder = false

    init(
        modelResourceManager: SAM3ModelResourceManager = SAM3ModelResourceManager(),
        clipModelResourceManager: CLIPModelResourceManager = CLIPModelResourceManager(),
    ) {
        self.sam3ModelResourceManager = modelResourceManager
        self.clipModelResourceManager = clipModelResourceManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Models")
                        .font(.system(size: 14, weight: .semibold))
                    Divider()

                    statusRow(
                        title: "SAM 3 model:",
                        statusTitle: sam3Status.displayTitle,
                        iconName: statusIconName(for: sam3Status),
                        color: statusColor(for: sam3Status),
                    )

                    Text(sam3Status.displayMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    statusRow(
                        title: "CLIP model:",
                        statusTitle: clipStatus.displayTitle,
                        iconName: statusIconName(for: clipStatus),
                        color: statusColor(for: clipStatus),
                    )

                    Text(clipStatus.displayMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: useCLIPForSimilarityBinding) {
                        Text("Use CLIP for similarity")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .disabled(!clipStatus.isInstalled)
                    .help(clipStatus.isInstalled ? "Use CLIP image embeddings for similarity indexing. If CLIP inference fails for an image, RawCull falls back to Vision feature prints." : "Install a valid CLIP model before enabling CLIP similarity.")

                    Text(similarityBackendMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(settingsManager.useCLIPForSimilarity && clipStatus.isInstalled ? .green : .secondary)
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
                .disabled(sam3Status.isInstalled)
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

    private var useCLIPForSimilarityBinding: Binding<Bool> {
        Binding(
            get: {
                settingsManager.useCLIPForSimilarity && clipStatus.isInstalled
            },
            set: { newValue in
                guard clipStatus.isInstalled else {
                    settingsManager.useCLIPForSimilarity = false
                    Task { await settingsManager.saveSettings() }
                    return
                }
                settingsManager.useCLIPForSimilarity = newValue
                Task { await settingsManager.saveSettings() }
            },
        )
    }

    private var similarityBackendMessage: String {
        if settingsManager.useCLIPForSimilarity, clipStatus.isInstalled {
            return "Similarity indexing will use CLIP image embeddings. If CLIP inference fails for an image, RawCull falls back to Vision feature prints."
        }
        if clipStatus.isInstalled {
            return "Similarity indexing currently uses Vision feature prints. Enable CLIP here to use CLIP image embeddings."
        }
        return "Similarity indexing currently uses Vision feature prints."
    }

    private func statusRow(
        title: String,
        statusTitle: String,
        iconName: String,
        color: Color,
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Text(statusTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color)

            Spacer()
        }
    }

    private func statusIconName(for status: SAM3ModelStatus) -> String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle"
        case .invalid: "xmark.circle.fill"
        }
    }

    private func statusIconName(for status: CLIPModelStatus) -> String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle"
        case .invalid: "xmark.circle.fill"
        }
    }

    private func statusColor(for status: SAM3ModelStatus) -> Color {
        switch status {
        case .installed: .green
        case .missing: .orange
        case .invalid: .red
        }
    }

    private func statusColor(for status: CLIPModelStatus) -> Color {
        switch status {
        case .installed: .green
        case .missing: .orange
        case .invalid: .red
        }
    }

    private func refreshStatus() {
        sam3Status = sam3ModelResourceManager.modelStatus()
        clipStatus = clipModelResourceManager.modelStatus()
        if !clipStatus.isInstalled, settingsManager.useCLIPForSimilarity {
            settingsManager.useCLIPForSimilarity = false
            Task { await settingsManager.saveSettings() }
        }
    }
}
