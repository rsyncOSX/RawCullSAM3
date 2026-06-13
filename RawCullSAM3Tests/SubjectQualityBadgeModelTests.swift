import CoreGraphics
@testable import RawCullSAM3
import Testing

private func makeSubjectEntry(
    hasMask: Bool = true,
    confidence: Float = 0.8,
    coverage: Float = 0.20,
    boundingBox: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
    isFresh: Bool = true,
) -> SAM3MaskInventoryEntry {
    SAM3MaskInventoryEntry(
        hasMask: hasMask,
        confidence: confidence,
        coverage: coverage,
        boundingBox: boundingBox,
        centroid: CGPoint(x: 0.5, y: 0.5),
        isFresh: isFresh,
    )
}

@Suite("SubjectQualityBadgeModel")
struct SubjectQualityBadgeModelTests {
    @Test("Missing mask is poor")
    func missingMaskIsPoor() {
        let model = SubjectQualityBadgeModel(entry: nil)

        #expect(model.level == .poor)
        #expect(model.label == "SAM --")
        #expect(model.helpText == "No cached SAM3 mask")
        #expect(model.isClipped == false)
    }

    @Test("Confident reasonable fresh unclipped mask is good")
    func goodMask() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(confidence: 0.84))

        #expect(model.level == .good)
        #expect(model.label == "SAM 84%")
        #expect(model.helpText.contains("coverage 20%"))
        #expect(model.helpText.contains("not clipped"))
        #expect(model.helpText.contains("fresh"))
    }

    @Test("Low confidence mask is warning")
    func lowConfidenceIsWarning() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(confidence: 0.69))

        #expect(model.level == .warning)
        #expect(model.label == "SAM 69%")
    }

    @Test("Near empty coverage is poor")
    func nearEmptyCoverageIsPoor() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(coverage: 0.004))

        #expect(model.level == .poor)
    }

    @Test("Low but measurable coverage is warning")
    func lowCoverageIsWarning() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(coverage: 0.01))

        #expect(model.level == .warning)
    }

    @Test("Broad coverage is warning and extremely broad coverage is poor")
    func broadCoverageClassifiesByWeakness() {
        let broad = SubjectQualityBadgeModel(entry: makeSubjectEntry(coverage: 0.71))
        let extremelyBroad = SubjectQualityBadgeModel(entry: makeSubjectEntry(coverage: 0.91))

        #expect(broad.level == .warning)
        #expect(extremelyBroad.level == .poor)
    }

    @Test("Frame edge clipping is warning")
    func clippedMaskIsWarning() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(
            boundingBox: CGRect(x: 0.02, y: 0.2, width: 0.3, height: 0.3),
        ))

        #expect(model.level == .warning)
        #expect(model.isClipped)
        #expect(model.helpText.contains("clipped at frame edge"))
    }

    @Test("Stale mask is warning")
    func staleMaskIsWarning() {
        let model = SubjectQualityBadgeModel(entry: makeSubjectEntry(isFresh: false))

        #expect(model.level == .warning)
        #expect(model.helpText.contains("stale"))
    }
}
