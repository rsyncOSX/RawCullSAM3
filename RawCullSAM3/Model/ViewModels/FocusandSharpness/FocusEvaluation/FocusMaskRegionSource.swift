import Foundation

enum FocusMaskRegionSource: String, Codable, Equatable {
    case none
    case saliency
    case afPoint
    case saliencyAndAF

    var title: String {
        switch self {
        case .none: "None"
        case .saliency: "Saliency"
        case .afPoint: "AF point"
        case .saliencyAndAF: "AF + saliency"
        }
    }
}
