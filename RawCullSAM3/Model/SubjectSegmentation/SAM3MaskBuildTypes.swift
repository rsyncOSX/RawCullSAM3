import Foundation

nonisolated struct SAM3MaskBuildRequest: Codable, Equatable {
    let catalogBookmark: Data
    let catalogPath: String
    let modelResourcesPath: String
    let maskCachePath: String
    let rawCullAppPath: String
    let parentProcessID: Int32
}

nonisolated struct SAM3MaskBuildSummary: Codable, Equatable {
    let total: Int
    let cached: Int
    let generated: Int
    let failed: Int
}

nonisolated struct SAM3MaskBuildEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case started
        case progress
        case completed
        case failed
    }

    let kind: Kind
    let completed: Int
    let total: Int
    let cached: Int
    let generated: Int
    let failed: Int
    let currentFileName: String?
    let message: String?

    static func started(total: Int) -> SAM3MaskBuildEvent {
        SAM3MaskBuildEvent(
            kind: .started,
            completed: 0,
            total: total,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileName: nil,
            message: nil,
        )
    }

    static func progress(_ progress: SubjectMaskPrefetchProgress, currentFileName: String?) -> SAM3MaskBuildEvent {
        SAM3MaskBuildEvent(
            kind: .progress,
            completed: progress.completed,
            total: progress.total,
            cached: progress.cached,
            generated: progress.generated,
            failed: progress.failed,
            currentFileName: currentFileName,
            message: nil,
        )
    }

    static func completed(_ summary: SAM3MaskBuildSummary) -> SAM3MaskBuildEvent {
        SAM3MaskBuildEvent(
            kind: .completed,
            completed: summary.total,
            total: summary.total,
            cached: summary.cached,
            generated: summary.generated,
            failed: summary.failed,
            currentFileName: nil,
            message: nil,
        )
    }

    static func failed(_ message: String) -> SAM3MaskBuildEvent {
        SAM3MaskBuildEvent(
            kind: .failed,
            completed: 0,
            total: 0,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileName: nil,
            message: message,
        )
    }

    var prefetchProgress: SubjectMaskPrefetchProgress? {
        guard kind == .started || kind == .progress || kind == .completed else { return nil }
        return SubjectMaskPrefetchProgress(
            completed: completed,
            total: total,
            cached: cached,
            generated: generated,
            failed: failed,
            currentFileID: nil,
        )
    }
}

