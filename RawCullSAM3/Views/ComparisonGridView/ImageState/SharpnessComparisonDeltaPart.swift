import Foundation

struct SharpnessComparisonDeltaPart: Equatable, Identifiable {
    var label: String
    var value: Int

    var id: String {
        label
    }

    var title: String {
        "\(label) \(formattedValue)"
    }

    private var formattedValue: String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
