import SwiftUI

struct ComparisonViewportInteractionState: Equatable {
    var scale: CGFloat = 1.0
    var lastScale: CGFloat = 1.0
    var offset: CGSize = .zero
    var lastOffset: CGSize = .zero
    var showFocusMask = false
    var showSubjectMask = false
    var showFocusPoints = false

    mutating func resetTransform() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
        showSubjectMask = false
    }
}
