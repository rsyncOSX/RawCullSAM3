import SwiftUI

nonisolated enum SubjectSegmentationControlState: Equatable {
    case idle
    case loading
    case ready(SubjectSegmentationDiagnostics)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

struct SubjectSegmentationControlsView: View {
    @Binding var showSubjectMask: Bool
    @Binding var prompt: SubjectSegmentationPrompt
    var maskAvailable: Bool
    var state: SubjectSegmentationControlState
    var density: ImageOverlayControlDensity = .regular
    var onToggle: () -> Void
    var onPromptChange: () -> Void
    @State private var showDiagnostics = false

    var body: some View {
        HStack(spacing: density == .compact ? 5 : 8) {
            Button {
                onToggle()
            } label: {
                Image(systemName: iconName)
                    .font(density == .compact ? .body : .title3)
                    .foregroundStyle(showSubjectMask ? .green : .primary)
                    .symbolEffect(.bounce, value: showSubjectMask)
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.isLoading)
            .help(helpText)

            Picker("SAM prompt", selection: $prompt) {
                ForEach(SubjectSegmentationPrompt.allCases) { prompt in
                    Text(prompt.title).tag(prompt)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: density == .compact ? 220 : 300)
            .disabled(state.isLoading)
            .onChange(of: prompt) { _, _ in onPromptChange() }
            .help("SAM subject prompt")

            statusView
        }
        .padding(.horizontal, density == .compact ? 6 : 10)
        .padding(.vertical, density == .compact ? 5 : 9)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .padding(density == .compact ? 2 : 10)
        .animation(.spring(duration: 0.3), value: showSubjectMask)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            EmptyView()

        case .loading:
            ProgressView()
                .controlSize(.small)
                .fixedSize()

        case let .ready(diagnostics):
            HStack(spacing: 5) {
                Text(statusText(diagnostics))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    showDiagnostics.toggle()
                } label: {
                    Text("SAM3")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.16), in: Capsule())
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help(diagnosticsHelpText(diagnostics))
                .popover(isPresented: $showDiagnostics, arrowEdge: .top) {
                    SubjectSegmentationDiagnosticsPopover(diagnostics: diagnostics)
                }
            }

        case let .failed(message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var iconName: String {
        if state.isLoading {
            "sparkle.magnifyingglass"
        } else if showSubjectMask {
            "sparkles.square.filled.on.square"
        } else {
            "sparkles.square.filled.on.square"
        }
    }

    private var helpText: String {
        if showSubjectMask {
            "Hide SAM subject mask"
        } else if maskAvailable {
            "Show SAM subject mask"
        } else {
            "Run SAM subject segmentation"
        }
    }

    private var buttonSize: CGFloat {
        density == .compact ? 20 : 28
    }

    private func statusText(_ diagnostics: SubjectSegmentationDiagnostics) -> String {
        let confidenceText = "\(Int((diagnostics.confidence * 100).rounded()))%"
        guard let totalMilliseconds = diagnostics.timing.totalMilliseconds else { return confidenceText }
        if totalMilliseconds >= 1000 {
            return "\(confidenceText) \(String(format: "%.1f", totalMilliseconds / 1000))s"
        }
        return "\(confidenceText) \(Int(totalMilliseconds.rounded()))ms"
    }

    private func diagnosticsHelpText(_ diagnostics: SubjectSegmentationDiagnostics) -> String {
        [
            "Core AI SAM3 local",
            "Model: \(diagnostics.modelVersion)",
            "Asset: \(diagnostics.assetName ?? "unknown")",
            "Prompt: \(diagnostics.prompt.title)",
            "Confidence: \(Int((diagnostics.confidence * 100).rounded()))%",
            "Input: \(sizeText(diagnostics.inputSize))",
            "Mask: \(sizeText(diagnostics.outputSize))",
            "Elapsed: \(elapsedText(diagnostics.timing.totalMilliseconds))"
        ].joined(separator: "\n")
    }
}

struct SubjectMaskToggleButton: View {
    @Binding var showSubjectMask: Bool
    var isEnabled: Bool
    var maskAvailable: Bool
    var state: SubjectSegmentationControlState
    var density: ImageOverlayControlDensity = .regular
    var onToggle: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { onToggle() }
        } label: {
            Group {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                } else {
                    Image(systemName: iconName)
                        .font(density == .compact ? .body : .title3)
                        .symbolEffect(.bounce, value: showSubjectMask)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .disabled(!isEnabled || state.isLoading)
        .help(helpText)
        .padding(.horizontal, density == .compact ? 6 : 10)
        .padding(.vertical, density == .compact ? 5 : 9)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .padding(density == .compact ? 2 : 10)
        .animation(.spring(duration: 0.3), value: showSubjectMask)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var foregroundStyle: Color {
        if !isEnabled {
            return .secondary
        }
        if showSubjectMask {
            return .green
        }
        if case .failed = state {
            return .orange
        }
        return .primary
    }

    private var iconName: String {
        if showSubjectMask {
            return "sparkles.square.filled.on.square"
        }
        return maskAvailable ? "sparkles.square.on.square" : "sparkle.magnifyingglass"
    }

    private var helpText: String {
        if !isEnabled {
            return "SAM mask requires JPG"
        }
        if state.isLoading {
            return "Building SAM subject mask"
        }
        if case let .failed(message) = state {
            return message
        }
        if showSubjectMask {
            return "Hide SAM subject mask"
        }
        if maskAvailable {
            return "Show cached SAM subject mask"
        }
        return "Run SAM subject segmentation"
    }

    private var buttonSize: CGFloat {
        density == .compact ? 20 : 28
    }
}

private struct SubjectSegmentationDiagnosticsPopover: View {
    let diagnostics: SubjectSegmentationDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Core AI SAM3 local", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                diagnosticsRow("Model", diagnostics.modelVersion)
                diagnosticsRow("Resource", diagnostics.resourceName ?? "unknown")
                diagnosticsRow("Asset", diagnostics.assetName ?? "unknown")
                diagnosticsRow("Prompt", diagnostics.prompt.title)
                diagnosticsRow("Confidence", "\(Int((diagnostics.confidence * 100).rounded()))%")
                diagnosticsRow("Input", sizeText(diagnostics.inputSize))
                diagnosticsRow("Mask", sizeText(diagnostics.outputSize))
                diagnosticsRow("Elapsed", elapsedText(diagnostics.timing.totalMilliseconds))
            }
            .font(.caption.monospacedDigit())
        }
        .padding(14)
        .frame(minWidth: 280, alignment: .leading)
    }

    private func diagnosticsRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private func sizeText(_ size: CGSize) -> String {
    "\(Int(size.width.rounded())) x \(Int(size.height.rounded()))"
}

private func elapsedText(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "unknown" }
    if milliseconds >= 1000 {
        return "\(String(format: "%.1f", milliseconds / 1000))s"
    }
    return "\(Int(milliseconds.rounded()))ms"
}
