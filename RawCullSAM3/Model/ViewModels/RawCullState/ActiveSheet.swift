import Foundation

enum ActiveSheet: String, Identifiable {
    case stats
    case scoringParams
    case extractJPGs

    var id: String {
        rawValue
    }
}
