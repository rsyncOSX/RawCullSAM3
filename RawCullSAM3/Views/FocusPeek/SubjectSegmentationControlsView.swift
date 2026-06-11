import SwiftUI

nonisolated enum SubjectSegmentationControlState: Equatable {
    case idle
    case loading
    case ready(confidence: Float, totalMilliseconds: Double?)
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

        case let .ready(confidence, totalMilliseconds):
            Text(statusText(confidence: confidence, totalMilliseconds: totalMilliseconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

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

    private func statusText(confidence: Float, totalMilliseconds: Double?) -> String {
        let confidenceText = "\(Int((confidence * 100).rounded()))%"
        guard let totalMilliseconds else { return confidenceText }
        if totalMilliseconds >= 1000 {
            return "\(confidenceText) \(String(format: "%.1f", totalMilliseconds / 1000))s"
        }
        return "\(confidenceText) \(Int(totalMilliseconds.rounded()))ms"
    }
}
