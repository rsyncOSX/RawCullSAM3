import Foundation

enum FocusEvidenceRegion: String, Codable, Equatable {
    case none
    case afCenter
    case afNeighborhood
    case afPoint
    case samSubject
    case saliency
    case global
    case mixed

    var title: String {
        switch self {
        case .none: "None"
        case .afCenter: "AF center"
        case .afNeighborhood: "AF neighborhood"
        case .afPoint: "AF point"
        case .samSubject: "SAM subject"
        case .saliency: "Saliency"
        case .global: "Global"
        case .mixed: "Mixed"
        }
    }

    nonisolated var isAFAnchored: Bool {
        switch self {
        case .afCenter, .afNeighborhood, .afPoint:
            true

        case .none, .samSubject, .saliency, .global, .mixed:
            false
        }
    }
}
