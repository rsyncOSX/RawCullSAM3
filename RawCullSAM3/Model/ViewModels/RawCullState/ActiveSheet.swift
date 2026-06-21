import Foundation

enum ActiveSheet: String, Identifiable {
    case stats
    case scoringParams

    var id: String {
        rawValue
    }
}
