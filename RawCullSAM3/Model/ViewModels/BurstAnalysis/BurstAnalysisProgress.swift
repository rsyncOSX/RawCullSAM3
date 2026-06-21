import Foundation

struct BurstAnalysisProgress: Codable, Equatable {
    var step: BurstAnalysisStep = .idle
    var total: Int = 0

    var isRunning: Bool {
        step != .idle
    }

    var isCountBased: Bool {
        total > 0
    }

    var statusText: String {
        switch step {
        case .idle: "Ready"
        case .loadingCache: "Loading burst analysis..."
        case .scoringSharpness: "Scoring sharpness..."
        case .indexingSimilarity: "Indexing similarity..."
        case .grouping: "Grouping bursts..."
        case .ranking: "Ranking burst candidates..."
        case .savingCache: "Saving burst analysis..."
        }
    }
}
