import Foundation
import RawCullCore

nonisolated struct BurstReviewStateSnapshot: Codable, Equatable {
    let signature: BurstGroupSignature
    let state: BurstReviewState
}
