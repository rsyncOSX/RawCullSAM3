import Foundation

enum RatingFilter: Hashable {
    case all
    case rejected // rating == -1
    case keepers // rating == 0
    case stars(Int) // rating == n, n in 2...5
}
