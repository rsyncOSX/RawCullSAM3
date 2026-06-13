import CoreGraphics
import Foundation

nonisolated enum SubjectQualityBadgeLevel: Equatable, Sendable {
    case good
    case warning
    case poor
}

/// UI-neutral summary of cached SAM 3 subject-mask quality.
nonisolated struct SubjectQualityBadgeModel: Sendable {
    static let goodConfidenceThreshold: Float = 0.70
    static let minimumReasonableCoverage: Float = 0.02
    static let maximumReasonableCoverage: Float = 0.70
    static let edgeClipMargin: CGFloat = 0.02

    let level: SubjectQualityBadgeLevel
    let label: String
    let helpText: String
    let isClipped: Bool

    init(entry: SAM3MaskInventoryEntry?) {
        guard let entry, entry.hasMask else {
            level = .poor
            label = "SAM --"
            helpText = "No cached SAM3 mask"
            isClipped = false
            return
        }

        isClipped = Self.isClipped(entry.boundingBox)
        label = "SAM \(Self.percent(entry.confidence))%"

        let veryWeak = entry.coverage <= 0.005 || entry.coverage >= 0.90 || entry.boundingBox == .zero
        let isGood = entry.confidence >= Self.goodConfidenceThreshold
            && (Self.minimumReasonableCoverage ... Self.maximumReasonableCoverage).contains(entry.coverage)
            && entry.isFresh
            && !isClipped

        if veryWeak {
            level = .poor
        } else if isGood {
            level = .good
        } else {
            level = .warning
        }

        helpText = Self.helpText(for: entry, isClipped: isClipped, level: level)
    }

    private static func isClipped(_ rect: CGRect) -> Bool {
        guard rect != .zero else { return false }
        return rect.minX <= edgeClipMargin
            || rect.minY <= edgeClipMargin
            || rect.maxX >= 1 - edgeClipMargin
            || rect.maxY >= 1 - edgeClipMargin
    }

    private static func percent(_ value: Float) -> Int {
        Int((max(0, min(value, 1)) * 100).rounded())
    }

    private static func helpText(
        for entry: SAM3MaskInventoryEntry,
        isClipped: Bool,
        level: SubjectQualityBadgeLevel,
    ) -> String {
        let quality = switch level {
        case .good: "Strong SAM3 subject mask"
        case .warning: "Check SAM3 subject mask"
        case .poor: "Weak SAM3 subject mask"
        }

        let clippedText = isClipped ? "clipped at frame edge" : "not clipped"
        let freshnessText = entry.isFresh ? "fresh" : "stale"
        return "\(quality): confidence \(percent(entry.confidence))%, coverage \(percent(entry.coverage))%, \(clippedText), \(freshnessText)"
    }
}
