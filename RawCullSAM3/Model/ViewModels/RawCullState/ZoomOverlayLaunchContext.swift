import Foundation

struct ZoomOverlayLaunchContext: Equatable {
    var initialSource: ImagePreviewSource
    var initialZoomMode: ZoomOverlayInitialZoomMode
    var showFocusPointsOnOpen: Bool

    static let `default` = ZoomOverlayLaunchContext(
        initialSource: .thumbnail,
        initialZoomMode: .fit,
        showFocusPointsOnOpen: false,
    )
}
