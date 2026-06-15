//
//  RawCullViewModel+Sharpness.swift
//  RawCull
//

import Foundation
import RawCullCore

extension RawCullViewModel {
    /// Auto-calibrates focus config from the current catalog, then scores and re-sorts.
    /// After a successful (non-cancelled) run, scores and saliency are persisted to SavedFiles.
    func calibrateAndScoreCurrentCatalog() async {
        await calibrateAndScoreFiles(sharpnessScoringTargetFiles)
    }

    func calibrateAndScoreBurstFiles(_ files: [FileItem]) async {
        await calibrateAndScoreFiles(files)
    }

    var sharpnessScoringTargetFiles: [FileItem] {
        let orderedFiles = sharpnessScoringOrderedFiles()
        if !selectedFileIDs.isEmpty {
            return orderedFiles.filter { selectedFileIDs.contains($0.id) }
        }

        if case let .stars(rating) = ratingFilter,
           (2 ... 5).contains(rating) {
            return orderedFiles.filter { getRating(for: $0) == rating }
        }

        return sharpnessScoringCatalogFiles
    }

    var sharpnessScoringTargetDescription: String {
        let count = sharpnessScoringTargetFiles.count
        if !selectedFileIDs.isEmpty {
            return "\(count) selected thumbnail\(count == 1 ? "" : "s")"
        }
        if case let .stars(rating) = ratingFilter,
           (2 ... 5).contains(rating) {
            return "\(count) \(rating)-star file\(count == 1 ? "" : "s")"
        }
        return "\(count) catalog file\(count == 1 ? "" : "s")"
    }

    func sharpnessScoringOrderedFiles() -> [FileItem] {
        let visibleFiles = filteredFiles.isEmpty ? sharpnessScoringCatalogFiles : filteredFiles
        var seenIDs = Set<FileItem.ID>()
        var orderedFiles: [FileItem] = []

        for file in visibleFiles where seenIDs.insert(file.id).inserted {
            orderedFiles.append(file)
        }

        for file in sharpnessScoringCatalogFiles where seenIDs.insert(file.id).inserted {
            orderedFiles.append(file)
        }

        return orderedFiles
    }

    private var sharpnessScoringCatalogFiles: [FileItem] {
        files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func calibrateAndScoreFiles(_ files: [FileItem]) async {
        guard !files.isEmpty else { return }
        await sharpnessModel.calibrateFromBurst(files)
        await sharpnessModel.scoreFiles(files)
        // scores is cleared at the start of scoreFiles and only written on clean completion —
        // an empty dict means the run was cancelled, so skip the write.
        if !sharpnessModel.scores.isEmpty {
            persistScoringResultsInMemory(files: files)
        }
        await handleSortOrderChange()
    }

    /// Merges current sharpness scores and saliency labels into cullingModel.savedFiles
    /// and lets the culling store coalesce persistence with other culling changes.
    func persistScoringResultsInMemory(files filesToPersist: [FileItem]? = nil) {
        guard let catalog = selectedSource?.url else { return }
        let scores = sharpnessModel.scores
        let saliency = sharpnessModel.saliencyInfo
        let signature = sharpnessModel.scoringSignature
        let filesForResults = filesToPersist ?? files

        let results = filesForResults.compactMap { file -> CullingScoringResult? in
            guard let score = scores[file.id] else { return nil }
            return CullingScoringResult(
                fileName: file.name,
                score: score,
                saliencySubject: saliency[file.id]?.subjectLabel,
                scoringSignature: signature,
                fileSize: file.size,
                modificationDate: file.dateModified,
            )
        }
        cullingModel.mergeScoringResults(results, in: catalog)
    }

    func loadPersistedScoringandSaliency() {
        guard let catalog = selectedSource?.url else { return }
        guard let catalogIndex = cullingModel.savedFiles.firstIndex(where: { $0.catalog == catalog }) else { return }
        guard let filerecords = cullingModel.savedFiles[catalogIndex].filerecords else { return }

        var preloadedScores: [UUID: Float] = [:]
        var preloadedSaliency: [UUID: SaliencyInfo] = [:]

        for file in files {
            // Find the matching file record for this file
            guard let fileRecord = filerecords.first(where: { $0.fileName == file.name }) else { continue }

            // Legacy unsigned scores remain in JSON for compatibility but are stale.
            let metadataMatches = fileRecord.sharpnessFileSize == file.size
                && fileRecord.sharpnessModificationDate.map { abs($0.timeIntervalSince(file.dateModified)) < 0.001 } == true
            guard fileRecord.sharpnessScoringSignature == sharpnessModel.scoringSignature, metadataMatches else { continue }

            if let score = fileRecord.sharpnessScore { preloadedScores[file.id] = score }

            if let subjectLabel = fileRecord.saliencySubject {
                // Create saliency info with the subject label
                preloadedSaliency[file.id] = SaliencyInfo(subjectLabel: subjectLabel)
            }
        }

        if !preloadedScores.isEmpty {
            sharpnessModel.applyPreloadedScores(
                files,
                preloadedScores: preloadedScores,
                preloadedSaliency: preloadedSaliency,
            )
        }
    }
}
