import SwiftUI

struct SubjectQualityBadgeView: View {
    let model: SubjectQualityBadgeModel
    var isCompact = true

    var body: some View {
        Text(model.label)
            .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, isCompact ? 4 : 5)
            .padding(.vertical, isCompact ? 2 : 3)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .help(model.helpText)
            .accessibilityLabel("SAM3 subject quality")
            .accessibilityValue(model.helpText)
    }

    private var color: Color {
        switch model.level {
        case .good: .green
        case .warning: .orange
        case .poor: .red
        }
    }
}
