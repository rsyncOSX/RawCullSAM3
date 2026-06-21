import Foundation

enum BurstAnalysisStep: String, Codable, Equatable {
    case idle
    case loadingCache
    case scoringSharpness
    case indexingSimilarity
    case grouping
    case ranking
    case savingCache
}
