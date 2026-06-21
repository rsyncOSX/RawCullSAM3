import Foundation

enum FocusEvidenceConfidence: String, Codable, Equatable {
    case high
    case medium
    case low

    var title: String {
        rawValue.capitalized
    }
}
