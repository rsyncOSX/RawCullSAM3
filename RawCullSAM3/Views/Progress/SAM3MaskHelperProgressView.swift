import SwiftUI

struct SAM3MaskHelperProgressView: View {
    let progress: SubjectMaskPrefetchProgress?
    let statusText: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView(value: fractionCompleted)
                    .frame(width: 120)

                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Button(cancelTitle, action: onCancel)
                    .disabled(isCompleted)
            }

            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let progress {
                HStack(spacing: 14) {
                    Text("\(progress.completed)/\(progress.total)")
                    Text("Cached \(progress.cached)")
                    Text("Generated \(progress.generated)")
                    Text("Failed \(progress.failed)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SAM3 mask creation progress")
    }

    private var title: String {
        isCompleted ? "Completed: restarting RawCull" : "Creating SAM3 masks"
    }

    private var detailText: String {
        statusText.isEmpty ? "Preparing helper process..." : statusText
    }

    private var isCompleted: Bool {
        statusText == "Completed: restarting RawCull"
    }

    private var cancelTitle: String {
        isTerminalError ? "Dismiss" : "Cancel"
    }

    private var isTerminalError: Bool {
        statusText.hasPrefix("Could not start") ||
            statusText.hasPrefix("SAM3 mask helper exited") ||
            statusText.hasSuffix("failed.")
    }

    private var fractionCompleted: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return Double(progress.completed) / Double(progress.total)
    }
}
