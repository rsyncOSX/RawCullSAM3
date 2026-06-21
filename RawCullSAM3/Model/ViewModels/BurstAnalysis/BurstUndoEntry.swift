import Foundation

struct BurstUndoEntry: Equatable {
    let groupID: Int
    let previousRatingsByFileName: [String: Int]
}
