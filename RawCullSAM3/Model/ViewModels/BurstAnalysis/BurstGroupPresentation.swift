import Foundation
import RawCullCore

struct BurstGroupPresentation: Equatable {
    nonisolated static func recommendationBadge(
        for candidate: BurstCandidateScore,
        in result: BurstAnalysisResult,
    ) -> String? {
        guard result.recommendedFileID == candidate.fileID else { return nil }

        if result.reviewState == .manualWinnerOverride {
            return "Manual"
        }

        switch result.confidence {
        case .high:
            return "Best"

        case .medium:
            return "Suggested"

        case .low:
            return "Check frame"
        }
    }
}
