import Foundation

struct FocusPatchRanking: Equatable {
    nonisolated let normalizedRect: CGRect
    nonisolated let robustTailScore: Float
    nonisolated let microContrast: Float
    nonisolated let coverage: Float
    nonisolated let distanceToAF: Float?
    nonisolated let silhouetteFraction: Float
    nonisolated let ringDetailScore: Float
    nonisolated let compactDetailScore: Float
    nonisolated let linearEdgePenalty: Float
    nonisolated let belowAFPenalty: Float
    nonisolated let eyeHeadHeuristicAdjustment: Float
    nonisolated let compositeScore: Float
    nonisolated let containsAFPoint: Bool

    nonisolated init(
        normalizedRect: CGRect,
        robustTailScore: Float,
        microContrast: Float,
        coverage: Float,
        distanceToAF: Float?,
        silhouetteFraction: Float,
        ringDetailScore: Float = 0,
        compactDetailScore: Float = 0,
        linearEdgePenalty: Float = 0,
        belowAFPenalty: Float = 0,
        eyeHeadHeuristicAdjustment: Float = 0,
        compositeScore: Float,
        containsAFPoint: Bool,
    ) {
        self.normalizedRect = normalizedRect
        self.robustTailScore = robustTailScore
        self.microContrast = microContrast
        self.coverage = coverage
        self.distanceToAF = distanceToAF
        self.silhouetteFraction = silhouetteFraction
        self.ringDetailScore = ringDetailScore
        self.compactDetailScore = compactDetailScore
        self.linearEdgePenalty = linearEdgePenalty
        self.belowAFPenalty = belowAFPenalty
        self.eyeHeadHeuristicAdjustment = eyeHeadHeuristicAdjustment
        self.compositeScore = compositeScore
        self.containsAFPoint = containsAFPoint
    }

    nonisolated static func == (lhs: FocusPatchRanking, rhs: FocusPatchRanking) -> Bool {
        lhs.normalizedRect == rhs.normalizedRect
            && lhs.robustTailScore == rhs.robustTailScore
            && lhs.microContrast == rhs.microContrast
            && lhs.coverage == rhs.coverage
            && lhs.distanceToAF == rhs.distanceToAF
            && lhs.silhouetteFraction == rhs.silhouetteFraction
            && lhs.ringDetailScore == rhs.ringDetailScore
            && lhs.compactDetailScore == rhs.compactDetailScore
            && lhs.linearEdgePenalty == rhs.linearEdgePenalty
            && lhs.belowAFPenalty == rhs.belowAFPenalty
            && lhs.eyeHeadHeuristicAdjustment == rhs.eyeHeadHeuristicAdjustment
            && lhs.compositeScore == rhs.compositeScore
            && lhs.containsAFPoint == rhs.containsAFPoint
    }
}
