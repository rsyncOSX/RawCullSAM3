import Foundation

struct SharpnessBreakdown: Equatable {
    let finalScore: Float
    let globalScore: Float?
    let subjectScore: Float?
    let afPointScore: Float?
    let samSubjectScore: Float?
    let samMaskCoverage: Float?
    let afInsideSAMMask: Bool?
    let samScoringBlend: String?
    let blurGateSigma: Float
    let subjectLabel: String?
    let subjectConfidence: Float?
    let focusFailureKind: FocusFailureKind
    var focusMaskRegionSource: FocusMaskRegionSource?
    var focusMaskVisualThreshold: Float?
    var focusEvidence: FocusEvidence?
    var scoringSource: SharpnessScoringSource = .embeddedPreview

    nonisolated init(
        finalScore: Float,
        globalScore: Float?,
        subjectScore: Float?,
        afPointScore: Float?,
        samSubjectScore: Float? = nil,
        samMaskCoverage: Float? = nil,
        afInsideSAMMask: Bool? = nil,
        samScoringBlend: String? = nil,
        blurGateSigma: Float,
        subjectLabel: String?,
        subjectConfidence: Float?,
        focusFailureKind: FocusFailureKind,
        focusMaskRegionSource: FocusMaskRegionSource? = nil,
        focusMaskVisualThreshold: Float? = nil,
        focusEvidence: FocusEvidence? = nil,
        scoringSource: SharpnessScoringSource = .embeddedPreview,
    ) {
        self.finalScore = finalScore
        self.globalScore = globalScore
        self.subjectScore = subjectScore
        self.afPointScore = afPointScore
        self.samSubjectScore = samSubjectScore
        self.samMaskCoverage = samMaskCoverage
        self.afInsideSAMMask = afInsideSAMMask
        self.samScoringBlend = samScoringBlend
        self.blurGateSigma = blurGateSigma
        self.subjectLabel = subjectLabel
        self.subjectConfidence = subjectConfidence
        self.focusFailureKind = focusFailureKind
        self.focusMaskRegionSource = focusMaskRegionSource
        self.focusMaskVisualThreshold = focusMaskVisualThreshold
        self.focusEvidence = focusEvidence
        self.scoringSource = scoringSource
    }
}
