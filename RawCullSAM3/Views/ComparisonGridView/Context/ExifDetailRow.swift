import Foundation

struct ExifDetailRow: Equatable, Identifiable {
    var label: String
    var value: String

    var id: String {
        label
    }
}
