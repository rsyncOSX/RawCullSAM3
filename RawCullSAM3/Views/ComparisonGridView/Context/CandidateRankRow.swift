import Foundation
import RawCullCore

struct CandidateRankRow: Equatable, Identifiable {
    var rank: Int
    var fileID: FileItem.ID
    var fileName: String
    var score: Float
    var isRecommended: Bool
    var isSecondBest: Bool
    var isManualWinner: Bool
    var isSelected: Bool

    var id: FileItem.ID {
        fileID
    }
}
