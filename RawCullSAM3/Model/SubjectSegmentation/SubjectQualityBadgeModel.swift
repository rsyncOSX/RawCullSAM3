import CoreGraphics
import Foundation

nonisolated enum SubjectQualityBadgeLevel: Equatable {
    case good
    case warning
    case poor
}

/// UI-neutral summary of cached SAM 3 subject-mask quality.
nonisolated struct SubjectQualityBadgeModel {
    static let minimumReasonableCoverage: Float = 0.02
    static let maximumReasonableCoverage: Float = 0.70
    static let minimumUsableCoverage: Float = 0.005
    static let maximumUsableCoverage: Float = 0.90
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
        label = switch Self.classify(entry: entry, isClipped: isClipped) {
        case .good: "SAM"
        case .warning: "SAM ?"
        case .poor: "SAM --"
        }

        level = Self.classify(entry: entry, isClipped: isClipped)
        helpText = Self.helpText(for: entry, isClipped: isClipped, level: level)
    }

    private static func classify(
        entry: SAM3MaskInventoryEntry,
        isClipped: Bool,
    ) -> SubjectQualityBadgeLevel {
        let unusable = entry.boundingBox == .zero
            || entry.coverage <= minimumUsableCoverage
            || entry.coverage >= maximumUsableCoverage
        guard !unusable else { return .poor }

        let cleanGeometry = (minimumReasonableCoverage ... maximumReasonableCoverage).contains(entry.coverage)
            && entry.isFresh
            && !isClipped

        return cleanGeometry ? .good : .warning
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
        case .good: "Usable SAM3 subject mask"
        case .warning: "SAM3 subject mask has cautions"
        case .poor: "No usable SAM3 subject mask"
        }

        let clippedText = isClipped ? "clipped at frame edge" : "not clipped"
        let freshnessText = entry.isFresh ? "fresh" : "stale"
        return "\(quality): coverage \(percent(entry.coverage))%, \(clippedText), \(freshnessText), model confidence \(percent(entry.confidence))%"
    }
}
