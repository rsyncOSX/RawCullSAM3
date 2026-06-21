import Foundation

enum MainViewMode: String, CaseIterable, Identifiable {
    case loupe
    case grid
    case similarityGrid
    case ratedGrid
    case comparisonGrid

    var id: String {
        rawValue
    }
}
