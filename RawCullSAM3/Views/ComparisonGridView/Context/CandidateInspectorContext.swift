import Foundation
import RawCullCore

struct CandidateInspectorContext {
    var file: FileItem
    var candidate: BurstCandidateScore
    var rank: Int
    var confidence: BurstDecisionConfidence
    var rating: Int
    var saliencyLabel: String?
    var sharpnessScore: Float?
    var sharpnessBreakdown: SharpnessBreakdown?
    var hasFocusPoints: Bool
    var exifSummary: ExifSummary
    var rankRows: [CandidateRankRow]
    var groupReasons: [String]
    var groupCautions: [String]

    static func make(
        selectedFile: FileItem?,
        result: BurstAnalysisResult?,
        files: [FileItem],
        saliencyInfo: [FileItem.ID: SaliencyInfo],
        sharpnessScores: [FileItem.ID: Float],
        sharpnessBreakdowns: [FileItem.ID: SharpnessBreakdown],
        focusPoints: [FocusPointsModel]?,
        rating: Int,
    ) -> Self? {
        guard let selectedFile,
              let result,
              let candidateIndex = result.candidates.firstIndex(where: { $0.fileID == selectedFile.id })
        else { return nil }

        let candidate = result.candidates[candidateIndex]
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let rankRows = result.candidates.enumerated().map { index, candidate in
            CandidateRankRow(
                rank: index + 1,
                fileID: candidate.fileID,
                fileName: filesByID[candidate.fileID]?.name ?? "Unknown file",
                score: candidate.overallScore,
                isRecommended: result.recommendedFileID == candidate.fileID,
                isSecondBest: result.secondBestFileID == candidate.fileID,
                isManualWinner: result.reviewState == .manualWinnerOverride
                    && result.recommendedFileID == candidate.fileID,
                isSelected: selectedFile.id == candidate.fileID,
            )
        }

        return CandidateInspectorContext(
            file: selectedFile,
            candidate: candidate,
            rank: candidateIndex + 1,
            confidence: result.confidence,
            rating: rating,
            saliencyLabel: saliencyInfo[selectedFile.id]?.subjectLabel,
            sharpnessScore: sharpnessScores[selectedFile.id],
            sharpnessBreakdown: sharpnessBreakdowns[selectedFile.id],
            hasFocusPoints: focusPointsAvailable(for: selectedFile, focusPoints: focusPoints),
            exifSummary: ExifSummary.make(from: selectedFile.exifData),
            rankRows: rankRows,
            groupReasons: result.reasons,
            groupCautions: result.cautions,
        )
    }

    private static func focusPointsAvailable(
        for file: FileItem,
        focusPoints: [FocusPointsModel]?,
    ) -> Bool {
        guard let focusPoints else { return file.afFocusNormalized != nil }
        return focusPoints.contains { model in
            model.sourceFile == file.name && !model.focusPoints.isEmpty
        } || file.afFocusNormalized != nil
    }
}
