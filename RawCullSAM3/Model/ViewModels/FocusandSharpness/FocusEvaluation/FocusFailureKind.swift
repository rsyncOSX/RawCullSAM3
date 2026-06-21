import Foundation

enum FocusFailureKind: String, Codable, Equatable {
    case none
    case motionBlur
    case missedFocus

    var title: String {
        switch self {
        case .none: "None"
        case .motionBlur: "Motion blur"
        case .missedFocus: "Missed focus"
        }
    }
}
