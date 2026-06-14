import SwiftUI

struct CandidateInspectorView: View {
    let context: CandidateInspectorContext?

    var body: some View {
        if let context {
            Form {
                ForEach(CandidateInspectorPresentation.make(context: context).sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            inspectorRow(row)
                        }
                    }
                }

                if !context.exifSummary.detailRows.isEmpty {
                    Section("Camera Settings") {
                        ForEach(context.exifSummary.detailRows) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                    }
                }

                Section("Rank Table") {
                    ForEach(context.rankRows) { row in
                        CandidateRankRowView(row: row)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Candidate Inspector")
        } else {
            ContentUnavailableView(
                "No Candidate Selected",
                systemImage: "sidebar.right",
                description: Text("Select a burst candidate in comparison view to inspect ranking evidence."),
            )
            .padding()
        }
    }

    @ViewBuilder
    private func inspectorRow(_ row: CandidateInspectorPresentation.Row) -> some View {
        if let label = row.label {
            LabeledContent(label, value: row.value)
                .foregroundStyle(color(for: row.style))
        } else {
            Text(row.value)
                .foregroundStyle(color(for: row.style))
        }
    }

    private func color(for style: CandidateInspectorPresentation.Row.Style) -> Color {
        switch style {
        case .normal: .primary
        case .secondary: .secondary
        case .caution: .orange
        }
    }
}

struct CandidateInspectorPresentation: Equatable {
    struct Section: Equatable, Identifiable {
        var title: String
        var rows: [Row]

        var id: String {
            title
        }
    }

    struct Row: Equatable {
        enum Style: Equatable {
            case normal
            case secondary
            case caution
        }

        var label: String?
        var value: String
        var style: Style = .normal
    }

    var sections: [Section]

    static func make(context: CandidateInspectorContext) -> Self {
        var sections: [Section] = [
            decisionSummary(context),
            decisionSignals(context)
        ]

        if let subjectSharpness = subjectSharpness(context) {
            sections.append(subjectSharpness)
        }
        if let technicalDetails = technicalDetails(context) {
            sections.append(technicalDetails)
        }
        if let notes = evaluationNotes(context) {
            sections.append(notes)
        }

        return CandidateInspectorPresentation(sections: sections)
    }

    private static func decisionSummary(_ context: CandidateInspectorContext) -> Section {
        var rows = [
            Row(label: "File", value: context.file.name),
            Row(label: "Rank", value: "#\(context.rank)"),
            Row(label: "Overall Score", value: percent(context.candidate.overallScore)),
            Row(label: "Confidence", value: context.confidence.title)
        ]

        if let caution = primaryCaution(for: context) {
            rows.append(Row(value: caution, style: .caution))
        } else if let reason = primaryReason(for: context) {
            rows.append(Row(value: reason, style: .secondary))
        }

        rows.append(Row(label: "Sharpness Rank", value: percent(context.candidate.sharpnessComponent)))
        if let burstRelativeSharpness = context.candidate.burstRelativeSharpnessComponent {
            rows.append(Row(label: "Burst-relative", value: percent(burstRelativeSharpness)))
        }

        if let breakdown = context.sharpnessBreakdown {
            appendSAMRows(from: breakdown, to: &rows)
        }

        return Section(title: "Decision Summary", rows: rows)
    }

    private static func decisionSignals(_ context: CandidateInspectorContext) -> Section {
        var rows = [
            Row(label: "Sharpness", value: percent(context.candidate.sharpnessComponent))
        ]
        if let burstRelativeSharpness = context.candidate.burstRelativeSharpnessComponent {
            rows.append(Row(label: "Burst-relative", value: percent(burstRelativeSharpness)))
        }
        rows.append(contentsOf: [
            Row(label: "Focus Point", value: percent(context.candidate.focusPointComponent)),
            Row(label: "Saliency", value: percent(context.candidate.saliencyComponent)),
            Row(label: "Metadata", value: percent(context.candidate.metadataComponent))
        ])
        return Section(title: "Decision Signals", rows: rows)
    }

    private static func subjectSharpness(_ context: CandidateInspectorContext) -> Section? {
        guard let breakdown = context.sharpnessBreakdown else { return nil }

        var rows: [Row] = []
        if let subjectScore = breakdown.subjectScore {
            rows.append(Row(label: "Subject Detail", value: percent(subjectScore)))
        }
        if let samSubjectScore = breakdown.samSubjectScore {
            rows.append(Row(label: "SAM Subject Detail", value: percent(samSubjectScore)))
        }
        if let afPointScore = breakdown.afPointScore {
            rows.append(Row(label: "AF Detail", value: percent(afPointScore)))
        }
        if let afInsideSAMMask = breakdown.afInsideSAMMask {
            rows.append(Row(label: "AF Inside SAM", value: yesNo(afInsideSAMMask)))
        }
        rows.append(Row(label: "Focus Flag", value: breakdown.focusFailureKind.title))

        return Section(title: "Subject Sharpness", rows: rows)
    }

    private static func technicalDetails(_ context: CandidateInspectorContext) -> Section? {
        guard let breakdown = context.sharpnessBreakdown else { return nil }

        var rows = [
            Row(label: "Source", value: breakdown.scoringSource.title),
            Row(label: "Blur Gate", value: decimal(breakdown.blurGateSigma))
        ]
        if let globalScore = breakdown.globalScore {
            rows.append(Row(label: "Global Detail", value: percent(globalScore)))
        }
        if let samMaskCoverage = breakdown.samMaskCoverage {
            rows.append(Row(label: "SAM Coverage", value: percent(samMaskCoverage)))
        }
        if let samScoringBlend = breakdown.samScoringBlend {
            rows.append(Row(label: "SAM Blend", value: samScoringBlend))
        }
        if let subjectLabel = breakdown.subjectLabel {
            rows.append(Row(label: "Subject Label", value: subjectLabel))
        }
        if let subjectConfidence = breakdown.subjectConfidence {
            rows.append(Row(label: "Subject Confidence", value: percent(subjectConfidence)))
        }
        if let regionSource = breakdown.focusMaskRegionSource {
            rows.append(Row(label: "Mask Region", value: regionSource.title))
        }
        if let visualThreshold = breakdown.focusMaskVisualThreshold {
            rows.append(Row(label: "Mask Threshold", value: decimal(visualThreshold)))
        }

        if let evidence = breakdown.focusEvidence {
            appendEvidenceRows(from: evidence, to: &rows)
        }

        return Section(title: "Technical Details", rows: rows)
    }

    private static func appendEvidenceRows(from evidence: FocusEvidence, to rows: inout [Row]) {
        rows.append(Row(label: "Winning Region", value: evidence.winningRegion.title))
        if let region = evidence.visualizedRegion {
            rows.append(Row(label: "Rendered Region", value: region.title))
        }
        if let style = evidence.overlayStyle {
            rows.append(Row(label: "Overlay Style", value: style.title))
        }
        if let localScore = evidence.scoringLocalDetailScore {
            rows.append(Row(label: "Scoring Local Detail", value: percent(localScore)))
        }
        if let afCenterScore = evidence.afCenterScore {
            rows.append(Row(label: "AF Center Detail", value: percent(afCenterScore)))
        }
        if let afNeighborhoodScore = evidence.afNeighborhoodScore {
            rows.append(Row(label: "AF Neighborhood Detail", value: percent(afNeighborhoodScore)))
        }
        if let afPatchScore = evidence.scoringAFLocalPatchScore {
            rows.append(Row(label: "Scoring AF Patch", value: percent(afPatchScore)))
        }
        if let subjectPatchScore = evidence.scoringSubjectInteriorPatchScore {
            rows.append(Row(label: "Scoring Subject Patch", value: percent(subjectPatchScore)))
        }
        rows.append(Row(label: "Saliency Candidates", value: "\(evidence.saliencyCandidateCount)"))
        if let reason = evidence.saliencySelectionReason {
            rows.append(Row(label: "Saliency Selection", value: reason))
        }
        if let confidence = evidence.focusEvidenceConfidence {
            rows.append(Row(label: "Location Confidence", value: confidence.title))
        }
        if let reason = evidence.focusEvidenceConfidenceReason {
            rows.append(Row(value: reason, style: evidenceNeedsReview(evidence) ? .caution : .secondary))
        }
        if let distance = evidence.afDistanceFromCentroid {
            rows.append(Row(label: "AF Distance", value: percent(distance)))
        }
        if let alignment = evidence.spatialAlignmentScore {
            rows.append(Row(label: "Spatial Alignment", value: percent(alignment)))
        }
        if let threshold = evidence.effectiveVisualThreshold {
            rows.append(Row(label: "Evidence Threshold", value: decimal(threshold)))
        }
        if let coverage = evidence.maskCoverage {
            rows.append(Row(label: "Evidence Coverage", value: percent(coverage)))
        }
        rows.append(Row(label: "Visibility Relaxed", value: yesNo(evidence.relaxedForVisibility)))
        if let dominance = evidence.localPatchDominance {
            rows.append(Row(label: "Patch Dominance", value: decimal(dominance)))
        }
        rows.append(Row(label: "Silhouette Penalty", value: evidence.silhouettePenaltyApplied ? "Applied" : "None"))
        for (index, patch) in evidence.patchRankings.prefix(3).enumerated() {
            rows.append(Row(label: "Patch \(index + 1)", value: patchSummary(patch)))
        }
        if evidenceNeedsReview(evidence) {
            rows.append(Row(
                value: "Review focus location: evidence is global-only or not aligned with the AF marker.",
                style: .caution,
            ))
        }
    }

    private static func evaluationNotes(_ context: CandidateInspectorContext) -> Section? {
        var rows: [Row] = []
        rows.append(contentsOf: context.candidate.reasons.map { Row(value: $0, style: .secondary) })
        rows.append(contentsOf: context.groupReasons.map { Row(value: $0, style: .secondary) })
        rows.append(contentsOf: context.candidate.cautions.map { Row(value: $0, style: .caution) })
        rows.append(contentsOf: context.groupCautions.map { Row(value: $0, style: .caution) })
        return rows.isEmpty ? nil : Section(title: "Evaluation Notes", rows: rows)
    }

    private static func appendSAMRows(from breakdown: SharpnessBreakdown, to rows: inout [Row]) {
        if let samScoringBlend = breakdown.samScoringBlend {
            rows.append(Row(label: "SAM Blend", value: samScoringBlend))
        }
        if let afInsideSAMMask = breakdown.afInsideSAMMask {
            rows.append(Row(label: "AF Inside SAM", value: yesNo(afInsideSAMMask)))
        }
        if let samSubjectScore = breakdown.samSubjectScore {
            rows.append(Row(label: "SAM Subject Detail", value: percent(samSubjectScore)))
        }
    }

    private static func primaryCaution(for context: CandidateInspectorContext) -> String? {
        context.candidate.cautions.first ?? context.groupCautions.first
    }

    private static func primaryReason(for context: CandidateInspectorContext) -> String? {
        context.candidate.reasons.first ?? context.groupReasons.first
    }

    private static func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func decimal(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func patchSummary(_ patch: FocusPatchRanking) -> String {
        let distance = patch.distanceToAF.map { String(format: "%.3f", $0) } ?? "—"
        return String(
            format: "%.3f  AF %@  cover %.2f  eye %+0.2f  ring %.2f  compact %.2f  line %.2f  below %.2f",
            patch.compositeScore,
            distance,
            patch.coverage,
            patch.eyeHeadHeuristicAdjustment,
            patch.ringDetailScore,
            patch.compactDetailScore,
            patch.linearEdgePenalty,
            patch.belowAFPenalty,
        )
    }

    private static func evidenceNeedsReview(_ evidence: FocusEvidence) -> Bool {
        evidence.visualizedRegion == .global || evidence.focusEvidenceConfidence == .low
    }
}

private struct CandidateRankRowView: View {
    let row: CandidateRankRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#\(row.rank)")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.fileName)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if row.isManualWinner {
                        rankBadge("Manual", color: .orange)
                    } else if row.isRecommended {
                        rankBadge("Best", color: .green)
                    } else if row.isSecondBest {
                        rankBadge("2nd", color: .blue)
                    }
                    if row.isSelected {
                        rankBadge("Selected", color: .accentColor)
                    }
                }
            }

            Spacer()

            Text("\(Int((row.score * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func rankBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }
}
