import Foundation
import RawCullCore

struct SaliencyDetection {
    nonisolated let candidates: [SaliencyCandidate]
    nonisolated let saliencyInfo: SaliencyInfo?
}
