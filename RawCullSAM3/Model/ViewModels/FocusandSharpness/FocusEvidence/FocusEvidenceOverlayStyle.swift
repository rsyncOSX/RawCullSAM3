import Foundation

enum FocusEvidenceOverlayStyle: String, Codable, Equatable {
    case subjectEdges
    case globalEdges

    var title: String {
        switch self {
        case .subjectEdges: "Subject edges"
        case .globalEdges: "Muted global edges"
        }
    }
}
