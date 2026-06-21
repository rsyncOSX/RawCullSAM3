import Foundation
import RawCullCore

struct BurstReviewStateSnapshot: Codable, Equatable {
    let signature: BurstGroupSignature
    let state: BurstReviewState
}
