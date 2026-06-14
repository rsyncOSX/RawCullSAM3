import Foundation
import RawCullCore
@testable import RawCullSAM3
import Testing

@Suite("ComparisonCandidateInspector")
struct ComparisonCandidateInspectorTests {
    @Test(.tags(.smoke))
    func `decision summary promotes ranking evidence and omits badge duplicated fields`() {
        let context = makeInspectorContext(
            breakdown: makeSAMSharpnessBreakdown(),
            candidateCautions: ["Top two are close"],
        )

        let presentation = CandidateInspectorPresentation.make(context: context)
        let summary = presentation.sections.first

        #expect(summary?.title == "Decision Summary")
        #expect(summary?.labels == [
            "File",
            "Rank",
            "Overall Score",
            "Confidence",
            "Sharpness Rank",
            "Burst-relative",
            "SAM Blend",
            "AF Inside SAM",
            "SAM Subject Detail",
        ])
        #expect(summary?.values.contains("Top two are close") == true)
        #expect(summary?.labels.contains("Rating") == false)
        #expect(summary?.labels.contains("Subject") == false)
        #expect(summary?.labels.contains("Focus Points") == false)
    }

    @Test(.tags(.smoke))
    func `sam rows are hidden cleanly when no sam diagnostics exist`() {
        let context = makeInspectorContext(breakdown: makeNonSAMSharpnessBreakdown())

        let presentation = CandidateInspectorPresentation.make(context: context)
        let allLabels = presentation.sections.flatMap(\.labels)

        #expect(!allLabels.contains("SAM Blend"))
        #expect(!allLabels.contains("AF Inside SAM"))
        #expect(!allLabels.contains("SAM Subject Detail"))
        #expect(!allLabels.contains("SAM Coverage"))
    }

    @Test(.tags(.smoke))
    func `subject and technical details are grouped below decision signals`() {
        let context = makeInspectorContext(breakdown: makeSAMSharpnessBreakdown())

        let presentation = CandidateInspectorPresentation.make(context: context)
        let titles = presentation.sections.map(\.title)
        let subjectIndex = titles.firstIndex(of: "Subject Sharpness")
        let technicalIndex = titles.firstIndex(of: "Technical Details")

        #expect(titles.prefix(4) == [
            "Decision Summary",
            "Decision Signals",
            "Subject Sharpness",
            "Technical Details",
        ])
        #expect(subjectIndex != nil)
        #expect(technicalIndex != nil)
        #expect(subjectIndex! < technicalIndex!)
        #expect(presentation.section("Subject Sharpness")?.labels.contains("SAM Subject Detail") == true)
        #expect(presentation.section("Technical Details")?.labels.contains("Evidence Coverage") == true)
        #expect(presentation.section("Technical Details")?.labels.contains("Silhouette Penalty") == true)
    }
}

private extension CandidateInspectorPresentation.Section {
    var labels: [String] {
        rows.compactMap(\.label)
    }

    var values: [String] {
        rows.map(\.value)
    }
}

private extension CandidateInspectorPresentation {
    func section(_ title: String) -> Section? {
        sections.first { $0.title == title }
    }
}

private func makeInspectorContext(
    breakdown: SharpnessBreakdown?,
    candidateCautions: [String] = [],
) -> CandidateInspectorContext {
    let file = makeInspectorTestFile("candidate.ARW")
    let candidate = BurstCandidateScore(
        fileID: file.id,
        overallScore: 0.92,
        sharpnessComponent: 0.84,
        burstRelativeSharpnessComponent: 0.88,
        focusPointComponent: 0.70,
        saliencyComponent: 0.75,
        metadataComponent: 0.90,
        confidence: .medium,
        reasons: ["Sharpest candidate leads"],
        cautions: candidateCautions,
    )

    return CandidateInspectorContext(
        file: file,
        candidate: candidate,
        rank: 1,
        confidence: .low,
        rating: 3,
        saliencyLabel: "bird",
        sharpnessScore: 0.84,
        sharpnessBreakdown: breakdown,
        hasFocusPoints: true,
        exifSummary: ExifSummary(exposureParts: [], gearParts: [], detailRows: []),
        rankRows: [
            CandidateRankRow(
                rank: 1,
                fileID: file.id,
                fileName: file.name,
                score: 0.92,
                isRecommended: true,
                isSecondBest: false,
                isManualWinner: false,
                isSelected: true,
            ),
        ],
        groupReasons: [],
        groupCautions: [],
    )
}

private func makeSAMSharpnessBreakdown() -> SharpnessBreakdown {
    SharpnessBreakdown(
        finalScore: 0.84,
        globalScore: 0.02,
        subjectScore: 0.73,
        afPointScore: 0.47,
        samSubjectScore: 0.83,
        samMaskCoverage: 0.03,
        afInsideSAMMask: true,
        samScoringBlend: "SAM + AF local",
        blurGateSigma: 0.32,
        subjectLabel: "animal",
        subjectConfidence: 0.53,
        focusFailureKind: .none,
        focusMaskRegionSource: .saliencyAndAF,
        focusMaskVisualThreshold: 0.52,
        focusEvidence: FocusEvidence(
            winningRegion: .samSubject,
            afCenterScore: 0.46,
            afNeighborhoodScore: 0.54,
            effectiveVisualThreshold: 0.52,
            maskCoverage: 0.03,
            relaxedForVisibility: false,
            visualizedRegion: .samSubject,
            spatialAlignmentScore: 0.91,
            silhouettePenaltyApplied: false,
            scoringAFLocalPatchScore: 0.73,
            scoringSubjectInteriorPatchScore: 1.00,
            scoringLocalDetailScore: 0.84,
            saliencyCandidateCount: 1,
            saliencySelectionReason: "AF overlap",
        ),
        scoringSource: .embeddedPreview,
    )
}

private func makeNonSAMSharpnessBreakdown() -> SharpnessBreakdown {
    SharpnessBreakdown(
        finalScore: 0.62,
        globalScore: 0.30,
        subjectScore: 0.62,
        afPointScore: 0.58,
        blurGateSigma: 0.18,
        subjectLabel: nil,
        subjectConfidence: nil,
        focusFailureKind: .none,
        focusMaskRegionSource: .saliencyAndAF,
        focusMaskVisualThreshold: 0.23,
        focusEvidence: FocusEvidence(
            winningRegion: .mixed,
            afCenterScore: 0.58,
            afNeighborhoodScore: 0.61,
            silhouettePenaltyApplied: false,
            scoringAFLocalPatchScore: 0.59,
            scoringSubjectInteriorPatchScore: 0.62,
            saliencyCandidateCount: 1,
        ),
        scoringSource: .embeddedPreview,
    )
}

private func makeInspectorTestFile(_ name: String) -> FileItem {
    FileItem(
        id: UUID(),
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        name: name,
        size: 1,
        dateModified: Date(timeIntervalSince1970: 0),
        exifData: nil,
        afFocusNormalized: nil,
    )
}
