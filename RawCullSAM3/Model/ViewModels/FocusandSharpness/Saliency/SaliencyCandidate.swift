import Foundation

struct SaliencyCandidate: Equatable {
    nonisolated let normalizedRect: CGRect
    nonisolated let confidence: Float
}
