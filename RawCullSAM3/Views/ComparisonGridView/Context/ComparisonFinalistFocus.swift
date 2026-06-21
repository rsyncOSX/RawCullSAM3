import Foundation
import RawCullCore

enum ComparisonFinalistFocus {
    nonisolated static func focusedIDs(from result: BurstAnalysisResult?) -> [FileItem.ID] {
        guard let result else { return [] }
        var focusedIDs: [FileItem.ID] = []
        append(result.recommendedFileID, to: &focusedIDs)
        append(result.secondBestFileID, to: &focusedIDs)
        if !focusedIDs.isEmpty {
            return focusedIDs
        }

        let candidateIDs = result.candidates.prefix(2).map(\.fileID)
        if !candidateIDs.isEmpty {
            return Array(candidateIDs)
        }
        return Array(result.fileIDs.prefix(2))
    }

    private nonisolated static func append(_ id: FileItem.ID?, to ids: inout [FileItem.ID]) {
        guard let id, !ids.contains(id) else { return }
        ids.append(id)
    }
}
