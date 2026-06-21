import Foundation

struct FocusEvidence: Equatable {
    nonisolated let winningRegion: FocusEvidenceRegion
    nonisolated let afCenterScore: Float?
    nonisolated let afNeighborhoodScore: Float?
    nonisolated var effectiveVisualThreshold: Float?
    nonisolated var maskCoverage: Float?
    nonisolated var relaxedForVisibility: Bool
    nonisolated var visualizedRegion: FocusEvidenceRegion?
    nonisolated var afDistanceFromCentroid: Float?
    nonisolated var patchRankings: [FocusPatchRanking]
    nonisolated var overlayStyle: FocusEvidenceOverlayStyle?
    nonisolated var focusEvidenceConfidence: FocusEvidenceConfidence?
    nonisolated var focusEvidenceConfidenceReason: String?
    nonisolated var spatialAlignmentScore: Float?
    nonisolated var localPatchDominance: Float?
    nonisolated var silhouettePenaltyApplied: Bool
    nonisolated var scoringAFLocalPatchScore: Float?
    nonisolated var scoringSubjectInteriorPatchScore: Float?
    nonisolated var scoringLocalDetailScore: Float?
    nonisolated var samSubjectScore: Float?
    nonisolated var samMaskCoverage: Float?
    nonisolated var afInsideSAMMask: Bool?
    nonisolated var samScoringBlend: String?
    nonisolated var saliencyCandidateCount: Int
    nonisolated var winningSaliencyRect: CGRect?
    nonisolated var saliencySelectionReason: String?

    nonisolated init(
        winningRegion: FocusEvidenceRegion,
        afCenterScore: Float? = nil,
        afNeighborhoodScore: Float? = nil,
        effectiveVisualThreshold: Float? = nil,
        maskCoverage: Float? = nil,
        relaxedForVisibility: Bool = false,
        visualizedRegion: FocusEvidenceRegion? = nil,
        afDistanceFromCentroid: Float? = nil,
        patchRankings: [FocusPatchRanking] = [],
        overlayStyle: FocusEvidenceOverlayStyle? = nil,
        focusEvidenceConfidence: FocusEvidenceConfidence? = nil,
        focusEvidenceConfidenceReason: String? = nil,
        spatialAlignmentScore: Float? = nil,
        localPatchDominance: Float? = nil,
        silhouettePenaltyApplied: Bool = false,
        scoringAFLocalPatchScore: Float? = nil,
        scoringSubjectInteriorPatchScore: Float? = nil,
        scoringLocalDetailScore: Float? = nil,
        samSubjectScore: Float? = nil,
        samMaskCoverage: Float? = nil,
        afInsideSAMMask: Bool? = nil,
        samScoringBlend: String? = nil,
        saliencyCandidateCount: Int = 0,
        winningSaliencyRect: CGRect? = nil,
        saliencySelectionReason: String? = nil,
    ) {
        self.winningRegion = winningRegion
        self.afCenterScore = afCenterScore
        self.afNeighborhoodScore = afNeighborhoodScore
        self.effectiveVisualThreshold = effectiveVisualThreshold
        self.maskCoverage = maskCoverage
        self.relaxedForVisibility = relaxedForVisibility
        self.visualizedRegion = visualizedRegion
        self.afDistanceFromCentroid = afDistanceFromCentroid
        self.patchRankings = patchRankings
        self.overlayStyle = overlayStyle
        self.focusEvidenceConfidence = focusEvidenceConfidence
        self.focusEvidenceConfidenceReason = focusEvidenceConfidenceReason
        self.spatialAlignmentScore = spatialAlignmentScore
        self.localPatchDominance = localPatchDominance
        self.silhouettePenaltyApplied = silhouettePenaltyApplied
        self.scoringAFLocalPatchScore = scoringAFLocalPatchScore
        self.scoringSubjectInteriorPatchScore = scoringSubjectInteriorPatchScore
        self.scoringLocalDetailScore = scoringLocalDetailScore
        self.samSubjectScore = samSubjectScore
        self.samMaskCoverage = samMaskCoverage
        self.afInsideSAMMask = afInsideSAMMask
        self.samScoringBlend = samScoringBlend
        self.saliencyCandidateCount = saliencyCandidateCount
        self.winningSaliencyRect = winningSaliencyRect
        self.saliencySelectionReason = saliencySelectionReason
    }
}
