import Foundation
import RawCullCore

struct CullingGridVisibleBurstGroup: Identifiable, Equatable {
    let id: Int
    let files: [FileItem]
}

struct CullingGridRenderCacheKey: Hashable {
    // periphery:ignore
    let burstGroupsCount: Int
    // periphery:ignore
    let burstStructureHash: Int
    // periphery:ignore
    let filesCount: Int
    // periphery:ignore
    let filesHash: Int
    // periphery:ignore
    let ratingFilter: GridRatingFilter
    // periphery:ignore
    let reviewQueueFilter: BurstReviewQueueFilter
    // periphery:ignore
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
    var bestInGroup: [Int: BestInGroupInfo] = [:]
    var hasSharpnessScoresSnapshot = false

    static func rebuild(
        files: [FileItem],
        burstGroups: [BurstGroup],
        scores: [UUID: Float],
        maxScore: Float,
        burstAnalysisResults: [Int: BurstAnalysisResult],
    ) -> CullingGridRenderCache {
        let lookup = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        var visibleGroups: [CullingGridVisibleBurstGroup] = []
        visibleGroups.reserveCapacity(burstGroups.count)
        var bestInGroup: [Int: BestInGroupInfo] = [:]

        for group in burstGroups {
            let visible = group.fileIDs.compactMap { lookup[$0] }
            guard !visible.isEmpty else { continue }
            visibleGroups.append(CullingGridVisibleBurstGroup(id: group.id, files: visible))

            if let result = burstAnalysisResults[group.id],
               result.reviewState == .manualWinnerOverride,
               let winnerID = result.recommendedFileID,
               let winner = visible.first(where: { $0.id == winnerID }) {
                bestInGroup[group.id] = RawCullViewModel.bestInGroupInfo(
                    file: winner,
                    scores: scores,
                    maxScore: maxScore,
                    isManualWinner: true,
                )
            } else if let info = RawCullViewModel.bestInGroupInfo(
                files: visible,
                scores: scores,
                maxScore: maxScore,
            ) {
                bestInGroup[group.id] = info
            }
        }

        return CullingGridRenderCache(
            visibleBurstGroups: visibleGroups,
            bestInGroup: bestInGroup,
            hasSharpnessScoresSnapshot: !scores.isEmpty,
        )
    }
}
