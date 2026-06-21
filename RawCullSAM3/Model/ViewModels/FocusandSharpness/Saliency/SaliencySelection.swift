import Foundation

struct SaliencySelection: Equatable {
    nonisolated let candidateCount: Int
    nonisolated let winningRegion: CGRect?
    nonisolated let reason: String?
}
