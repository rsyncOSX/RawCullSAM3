import Foundation
import RawCullCore

struct CullingGridVisibleBurstGroup: Identifiable, Equatable {
    let id: Int
    let files: [FileItem]
}

struct CullingGridRenderCacheKey: Hashable {
    let burstGroupsCount: Int
    let burstStructureHash: Int
    let filesCount: Int
    let filesHash: Int
    let ratingFilter: GridRatingFilter
    let reviewQueueFilter: BurstReviewQueueFilter
    let scoresHash: Int

    init(
        burstGroups: [BurstGroup],
        files: [FileItem],
        ratingFilter: GridRatingFilter,
        reviewQueueFilter: BurstReviewQueueFilter,
        scores: [UUID: Float],
        maxScore: Float,
        burstAnalysisResults: [Int: BurstAnalysisResult],
    ) {
        var structureHasher = Hasher()
        for group in burstGroups {
            structureHasher.combine(group.id)
            structureHasher.combine(group.fileIDs.count)
            for fileID in group.fileIDs {
                structureHasher.combine(fileID)
            }
            if let result = burstAnalysisResults[group.id] {
                structureHasher.combine(result.recommendedFileID)
                structureHasher.combine(result.reviewState.rawValue)
            }
        }

        var filesHasher = Hasher()
        for file in files {
            filesHasher.combine(file.id)
        }

        var scoresHasher = Hasher()
        scoresHasher.combine(maxScore)
        for (id, score) in scores.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            scoresHasher.combine(id)
            scoresHasher.combine(score)
        }

        self.burstGroupsCount = burstGroups.count
        self.burstStructureHash = structureHasher.finalize()
        self.filesCount = files.count
        self.filesHash = filesHasher.finalize()
        self.ratingFilter = ratingFilter
        self.reviewQueueFilter = reviewQueueFilter
        self.scoresHash = scoresHasher.finalize()
    }
}

struct CullingGridRenderCache {
    var visibleBurstGroups: [CullingGridVisibleBurstGroup] = []
    var hasSharpnessScoresSnapshot = false

    static func rebuild(
        files: [FileItem],
        burstGroups: [BurstGroup],
        scores: [UUID: Float],
    ) -> CullingGridRenderCache {
        let lookup = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        var visibleGroups: [CullingGridVisibleBurstGroup] = []
        visibleGroups.reserveCapacity(burstGroups.count)

        for group in burstGroups {
            let visible = group.fileIDs.compactMap { lookup[$0] }
            guard !visible.isEmpty else { continue }
            visibleGroups.append(CullingGridVisibleBurstGroup(id: group.id, files: visible))
        }

        return CullingGridRenderCache(
            visibleBurstGroups: visibleGroups,
            hasSharpnessScoresSnapshot: !scores.isEmpty,
        )
    }
}
