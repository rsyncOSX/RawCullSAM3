import RawCullCore
import SwiftUI

struct ComparisonImageState: Identifiable {
    let id: FileItem.ID
    var cgImage: CGImage?
    var nsImage: NSImage?
    var focusMask: CGImage?
    var subjectMask: CGImage?
    var sharpnessBreakdown: SharpnessBreakdown?
    var isLoading = false
}
