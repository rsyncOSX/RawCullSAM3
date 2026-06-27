//
//  RawCullViewModel+BurstGrouping.swift
//  RawCull
//

import CoreImage
import Foundation
import RawCullCore

enum DeepAIReviewPreset: String, CaseIterable, Identifiable, Codable {
    case auto
    case fullSubject
    case headFace

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .fullSubject: "Full Subject"
        case .headFace: "Head / Face"
        }
    }
}

enum DeepAIReviewConfidence: String, Codable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

struct DeepAIReviewCandidate: Identifiable, Equatable {
    var id: FileItem.ID {
        fileID
    }

    let fileID: FileItem.ID
    let fileName: String
    let rank: Int
    var isCompleted = true
    let deepScore: Float?
    let normalSharpnessScore: Float?
    let broadSAMScore: Float?
    let localDetailScore: Float?
    let fineDetailScore: Float?
    let maskPromptUsed: SubjectSegmentationPrompt?
    let maskCoverage: Float?
    let afInsideMask: Bool?
    var promptVerified: Bool?
    let usedFallbackMask: Bool
    let caution: String?

    var maskVerificationLabel: String {
        guard let promptVerified else { return "--" }
        return promptVerified ? "OK" : "Miss"
    }
}

struct DeepAIReviewResult: Equatable {
    let groupID: Int
    let groupSignature: BurstGroupSignature?
    let preset: DeepAIReviewPreset
    let candidates: [DeepAIReviewCandidate]
    let recommendedFileID: FileItem.ID?
    let confidence: DeepAIReviewConfidence
    let reasons: [String]
    let cautions: [String]
    let timestamp: Date

    var recommendedCandidate: DeepAIReviewCandidate? {
        recommendedFileID.flatMap { id in candidates.first { $0.fileID == id } }
    }

    var recommendationLabel: String {
        guard let recommendedCandidate else { return "Deep: review" }
        return "Deep: frame \(recommendedCandidate.rank)"
    }

    var explanation: String {
        let items = reasons + cautions
        return items.prefix(3).joined(separator: " · ")
    }
}

@Observable @MainActor
final class DeepAIReviewModel {
    var results: [Int: DeepAIReviewResult] = [:]
    var isRunning = false
    var activeGroupID: Int?
    var presentedGroupID: Int?
    var preset: DeepAIReviewPreset = .auto
    var statusText = ""

    func result(for groupID: Int) -> DeepAIReviewResult? {
        results[groupID]
    }
}

extension RawCullViewModel {
    // MARK: - Intelligent burst analysis

    /// Run the full intelligent burst analysis pipeline: load cache when valid,
    /// score sharpness, index similarity, group bursts, rank candidates, and
    /// persist the analysis artifacts.
    func analyzeBursts() async {
        let sorted = burstAnalysisTargetFiles
        guard let catalog = selectedSource?.url,
              !sorted.isEmpty,
              !isCreatingSAM3Masks
        else { return }

        burstAnalysisTask?.cancel()
        burstAnalysisGeneration &+= 1
        let generation = burstAnalysisGeneration
        let task = Task {
            await self.performBurstAnalysis(
                files: sorted,
                catalog: catalog,
                generation: generation,
            )
        }
        burstAnalysisTask = task
        await task.value
        if burstAnalysisGeneration == generation {
            burstAnalysisTask = nil
        }
    }

    private func performBurstAnalysis(
        files sorted: [FileItem],
        catalog: URL,
        generation: Int,
    ) async {
        defer {
            if isCurrentBurstAnalysis(generation: generation, catalog: catalog) {
                burstAnalysisProgress = BurstAnalysisProgress()
            }
        }

        await SettingsViewModel.shared.ensureLoaded()
        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        let preferredEmbeddingBackend = SimilarityScoringModel.preferredEmbeddingBackend(
            useCLIPForSimilarity: SettingsViewModel.shared.useCLIPForSimilarity,
        )
        let similarityGroupingSignature = currentBurstSimilarityGroupingSignature(
            embeddingBackend: preferredEmbeddingBackend,
        )

        burstAnalysisProgress = BurstAnalysisProgress(step: .loadingCache)
        if let snapshot = await burstAnalysisCache.load(
            catalog: catalog,
            files: sorted,
            thumbnailMaxPixelSize: sharpnessModel.effectiveThumbnailMaxPixelSize,
            sharpnessSignature: currentBurstSharpnessSignature,
            similarityGroupingSignature: similarityGroupingSignature,
        ) {
            guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
            applyCachedBurstAnalysis(remapCachedSnapshot(snapshot, to: sorted), files: sorted)
            burstAnalysisScopeFiles = sorted
            burstAnalysisScopeCatalog = catalog
            return
        }

        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        if !sharpnessModel.hasCurrentScores(for: sorted) {
            burstAnalysisProgress = BurstAnalysisProgress(
                step: .scoringSharpness,
                total: sorted.count,
            )
            await calibrateAndScoreBurstFiles(sorted)
        }

        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        if !similarityModel.hasCurrentEmbeddings(for: sorted, backend: preferredEmbeddingBackend) {
            burstAnalysisProgress = BurstAnalysisProgress(
                step: .indexingSimilarity,
                total: sorted.count,
            )
            await similarityModel.indexFiles(sorted)
        }

        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        burstAnalysisProgress = BurstAnalysisProgress(step: .grouping)
        await similarityModel.groupBursts(files: sorted)

        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        burstAnalysisProgress = BurstAnalysisProgress(step: .ranking)
        recomputeBurstRankings(files: sorted)

        guard isCurrentBurstAnalysis(generation: generation, catalog: catalog) else { return }
        burstAnalysisProgress = BurstAnalysisProgress(step: .savingCache)
        burstAnalysisScopeFiles = sorted
        burstAnalysisScopeCatalog = catalog
        await saveBurstAnalysisCache(catalog: catalog, files: sorted)
    }

    private func isCurrentBurstAnalysis(generation: Int, catalog: URL) -> Bool {
        !Task.isCancelled &&
            burstAnalysisGeneration == generation &&
            selectedSource?.url == catalog
    }

    /// Clear loaded burst analysis artifacts, delete the saved burst cache for
    /// the current catalog, and run a fresh analysis pass.
    func reindexBurstAnalysis() async {
        guard let catalog = selectedSource?.url,
              !burstAnalysisTargetFiles.isEmpty,
              !isCreatingSAM3Masks
        else { return }

        clearLoadedBurstAnalysisForReindex()
        await burstAnalysisCache.delete(catalog: catalog)
        await analyzeBursts()
    }

    // MARK: - Re-clustering on threshold change

    /// Re-run burst clustering with the current sensitivity threshold.
    /// Requires embeddings to already be computed — no-ops otherwise.
    func reGroupBursts() async {
        guard !similarityModel.embeddings.isEmpty,
              !isCreatingSAM3Masks,
              let catalog = selectedSource?.url
        else { return }
        let sorted = burstAnalysisTargetFiles
        guard !sorted.isEmpty else { return }
        guard !Task.isCancelled else { return }
        let savedReviewStates = reviewStateSnapshots(catalog: catalog, files: sorted)
        await similarityModel.groupBursts(files: sorted)
        guard !Task.isCancelled, selectedSource?.url == catalog else { return }
        burstReviewStates = reviewStates(
            from: savedReviewStates,
            files: sorted,
            catalog: catalog,
        )
        recomputeBurstRankings(files: sorted)
        pruneStaleDeepAIReviewResults()
    }

    // MARK: - User actions

    var isDeepAIReviewUnavailable: Bool {
        isCreatingSAM3Masks ||
            sharpnessModel.isScoring ||
            similarityModel.isIndexing ||
            similarityModel.isGrouping ||
            burstAnalysisProgress.isRunning ||
            deepAIReviewModel.isRunning
    }

    func presentDeepAIReview(groupID: Int) {
        if let result = deepAIReviewModel.results[groupID],
           result.groupSignature != currentBurstGroupSignature(groupID: groupID) {
            deepAIReviewModel.results[groupID] = nil
        }
        deepAIReviewModel.presentedGroupID = groupID
    }

    func deepAIReviewResult(for groupID: Int) -> DeepAIReviewResult? {
        guard let result = deepAIReviewModel.result(for: groupID),
              result.groupSignature == currentBurstGroupSignature(groupID: groupID)
        else { return nil }
        return result
    }

    func runDeepAIReview(for groupFiles: [FileItem]) async {
        guard !groupFiles.isEmpty,
              !isDeepAIReviewUnavailable,
              let catalog = selectedSource?.url
        else { return }

        let groupID = groupID(for: groupFiles)
        guard groupID >= 0 else { return }

        deepAIReviewTask?.cancel()
        deepAIReviewGeneration &+= 1
        let generation = deepAIReviewGeneration
        let task = Task {
            await self.performDeepAIReview(
                for: groupFiles,
                groupID: groupID,
                catalog: catalog,
                generation: generation,
            )
        }
        deepAIReviewTask = task
        await task.value
        if deepAIReviewGeneration == generation {
            deepAIReviewTask = nil
        }
    }

    private func performDeepAIReview(
        for groupFiles: [FileItem],
        groupID: Int,
        catalog: URL,
        generation: Int,
    ) async {
        deepAIReviewModel.isRunning = true
        deepAIReviewModel.activeGroupID = groupID
        deepAIReviewModel.statusText = "Preparing deep review..."

        defer {
            if isCurrentDeepAIReview(generation: generation, catalog: catalog) {
                deepAIReviewModel.isRunning = false
                deepAIReviewModel.activeGroupID = nil
                deepAIReviewModel.statusText = ""
            }
        }

        let candidateFiles = deepAIReviewCandidateFiles(groupFiles: groupFiles, groupID: groupID)
        let engine = FocusMaskEngine()
        let baseConfig = sharpnessModel.effectiveFocusConfig
        let preset = deepAIReviewModel.preset
        var rows: [DeepAIReviewCandidate] = []

        deepAIReviewModel.results[groupID] = makeDeepAIReviewResult(
            groupID: groupID,
            groupFiles: groupFiles,
            candidateRows: candidateFiles.enumerated().map { index, file in
                DeepAIReviewCandidate(
                    fileID: file.id,
                    fileName: file.name,
                    rank: index + 1,
                    isCompleted: false,
                    deepScore: nil,
                    normalSharpnessScore: sharpnessModel.scores[file.id],
                    broadSAMScore: nil,
                    localDetailScore: nil,
                    fineDetailScore: nil,
                    maskPromptUsed: nil,
                    maskCoverage: nil,
                    afInsideMask: nil,
                    promptVerified: nil,
                    usedFallbackMask: false,
                    caution: nil,
                )
            },
            preset: preset,
        )

        for (rank, file) in candidateFiles.enumerated() {
            guard isCurrentDeepAIReview(generation: generation, catalog: catalog) else { return }
            deepAIReviewModel.statusText = "Deep reviewing \(file.name)..."
            var fileConfig = baseConfig
            fileConfig.iso = file.exifData?.isoValue ?? 400
            fileConfig.apertureHint = FocusDetectorConfig.ApertureHint.from(aperture: file.exifData?.apertureValue)

            let maskChoice = await bestDeepAIReviewMask(
                for: file,
                preset: preset,
                subjectLabel: sharpnessModel.saliencyInfo[file.id]?.subjectLabel,
            )
            guard isCurrentDeepAIReview(generation: generation, catalog: catalog) else { return }
            let deepAnalysis: FocusMaskEngine.DeepAISharpnessAnalysis? = if let mask = maskChoice?.result.mask {
                await engine.computeDeepAIReviewScore(
                    fromRawURL: file.url,
                    config: fileConfig,
                    thumbnailMaxPixelSize: SharpnessScoringSizeOption.maximumPixelSize,
                    afPoint: file.afFocusNormalized,
                    scoringSource: sharpnessModel.scoringSource,
                    subjectMask: mask,
                )
            } else {
                nil
            }
            guard isCurrentDeepAIReview(generation: generation, catalog: catalog) else { return }
            let promptVerified = Self.deepAIReviewPromptVerified(
                preset: preset,
                maskChoice: maskChoice,
            )

            let caution: String? = if maskChoice == nil {
                "No usable SAM mask"
            } else if promptVerified == false, preset == .headFace {
                "Specific prompt not found"
            } else if deepAnalysis == nil {
                "Deep sharpness unavailable"
            } else if deepAnalysis?.usableLocalPatch == false {
                "No reliable local patch"
            } else if deepAnalysis?.backgroundDominancePenaltyApplied == true {
                "Background detail dominated"
            } else {
                nil
            }

            rows.append(DeepAIReviewCandidate(
                fileID: file.id,
                fileName: file.name,
                rank: rank + 1,
                deepScore: deepAnalysis?.finalScore,
                normalSharpnessScore: sharpnessModel.scores[file.id],
                broadSAMScore: deepAnalysis?.broadSubjectScore,
                localDetailScore: deepAnalysis?.localDetailScore,
                fineDetailScore: deepAnalysis?.fineDetailScore,
                maskPromptUsed: maskChoice?.result.prompt,
                maskCoverage: deepAnalysis?.maskCoverage ?? maskChoice?.geometry.coverage,
                afInsideMask: deepAnalysis?.afInsideMask,
                promptVerified: promptVerified,
                usedFallbackMask: maskChoice?.usedFallback ?? false,
                caution: caution,
            ))

            let completedIDs = Set(rows.map(\.fileID))
            let placeholders = candidateFiles
                .enumerated()
                .filter { !completedIDs.contains($0.element.id) }
                .map { index, file in
                    DeepAIReviewCandidate(
                        fileID: file.id,
                        fileName: file.name,
                        rank: index + 1,
                        isCompleted: false,
                        deepScore: nil,
                        normalSharpnessScore: sharpnessModel.scores[file.id],
                        broadSAMScore: nil,
                        localDetailScore: nil,
                        fineDetailScore: nil,
                        maskPromptUsed: nil,
                        maskCoverage: nil,
                        afInsideMask: nil,
                        promptVerified: nil,
                        usedFallbackMask: false,
                        caution: nil,
                    )
                }
            deepAIReviewModel.results[groupID] = makeDeepAIReviewResult(
                groupID: groupID,
                groupFiles: groupFiles,
                candidateRows: rows + placeholders,
                preset: preset,
            )
        }

        guard isCurrentDeepAIReview(generation: generation, catalog: catalog) else { return }
        let result = makeDeepAIReviewResult(
            groupID: groupID,
            groupFiles: groupFiles,
            candidateRows: rows,
            preset: preset,
        )
        deepAIReviewModel.results[groupID] = result
        if deepAIReviewModel.presentedGroupID == nil {
            deepAIReviewModel.presentedGroupID = groupID
        }
    }

    private func isCurrentDeepAIReview(generation: Int, catalog: URL) -> Bool {
        !Task.isCancelled &&
            deepAIReviewGeneration == generation &&
            selectedSource?.url == catalog
    }

    /// Rate the recommended frame in `groupFiles` at ★★★ and reject all others.
    func keepBestInGroup(from groupFiles: [FileItem]) {
        guard !groupFiles.isEmpty,
              !isCreatingSAM3Masks
        else { return }
        let groupID = groupID(for: groupFiles)
        guard canApplyOneClickCulling(groupID: groupID) else { return }
        let best = manualOverrideWinner(in: groupFiles)?.file
            ?? burstAnalysisResults[groupID]?.recommendedFileID
            .flatMap { id in groupFiles.first { $0.id == id } }
            ?? Self.sharpestFile(in: groupFiles, scores: sharpnessModel.scores)
            ?? groupFiles[0]
        let others = groupFiles.filter { $0.id != best.id }
        captureUndo(groupID: groupID, files: groupFiles)
        updateRating(for: best, rating: 3)
        if !others.isEmpty {
            updateRating(for: others, rating: -1)
        }
        markDecisionApplied(groupID: groupID)
    }

    func setManualBurstWinner(_ winner: FileItem, in groupFiles: [FileItem]) {
        guard let selectedSource,
              !isCreatingSAM3Masks,
              groupFiles.contains(where: { $0.id == winner.id })
        else { return }

        let override = BurstWinnerOverride(
            winnerFileName: winner.name,
            memberFileNames: groupFiles.map(\.name),
        )
        cullingModel.upsertBurstWinnerOverride(override, in: selectedSource.url)
        updateRating(for: winner, rating: 3)
        applyManualWinnerOverrides(files: burstAnalysisTargetFiles)
    }

    func markDeepAIReviewWinner(_ result: DeepAIReviewResult?, in groupFiles: [FileItem]) {
        guard let selectedSource,
              !isCreatingSAM3Masks,
              let result,
              result.groupSignature == BurstGroupSignature(files: groupFiles, catalog: selectedSource.url),
              let winner = result.recommendedFileID.flatMap({ id in groupFiles.first { $0.id == id } })
        else { return }

        let override = BurstWinnerOverride(
            winnerFileName: winner.name,
            memberFileNames: groupFiles.map(\.name),
        )
        cullingModel.upsertBurstWinnerOverride(override, in: selectedSource.url)
        applyManualWinnerOverrides(files: burstAnalysisTargetFiles)
    }

    /// Rate the recommended frame at ★★★, second best at ★★, and reject others.
    func keepTopTwoInGroup(from groupFiles: [FileItem]) {
        guard !groupFiles.isEmpty,
              !isCreatingSAM3Masks
        else { return }
        let groupID = groupID(for: groupFiles)
        guard canApplyOneClickCulling(groupID: groupID) else { return }
        let result = burstAnalysisResults[groupID]
        let rankedIDs = result?.candidates.map(\.fileID) ?? groupFiles
            .sorted { (sharpnessModel.scores[$0.id] ?? 0) > (sharpnessModel.scores[$1.id] ?? 0) }
            .map(\.id)
        let top = Set(rankedIDs.prefix(2))
        captureUndo(groupID: groupID, files: groupFiles)
        if let firstID = rankedIDs.first, let first = groupFiles.first(where: { $0.id == firstID }) {
            updateRating(for: first, rating: 3)
        }
        if rankedIDs.count > 1,
           let second = groupFiles.first(where: { $0.id == rankedIDs[1] }) {
            updateRating(for: second, rating: 2)
        }
        let others = groupFiles.filter { !top.contains($0.id) }
        if !others.isEmpty {
            updateRating(for: others, rating: -1)
        }
        markDecisionApplied(groupID: groupID)
    }

    func compareBurstGroup(_ groupFiles: [FileItem]) {
        guard !groupFiles.isEmpty,
              !isCreatingSAM3Masks
        else { return }
        let groupID = groupID(for: groupFiles)
        activeBurstComparisonGroupID = groupID
        let rankedIDs = burstAnalysisResults[groupID]?.candidates.map(\.fileID) ?? groupFiles.map(\.id)
        comparisonFileIDs = Array(rankedIDs.prefix(4))
        selectedFileID = comparisonFileIDs.first
        selectMainViewMode(.comparisonGrid)
    }

    func returnToActiveBurstGroupView() {
        closeZoomOverlay()
        activeBurstComparisonGroupID = nil
        mainViewMode = .similarityGrid
        similarityModel.burstModeActive = true
    }

    func undoLastBurstAction() {
        guard let entry = lastBurstUndoEntry,
              let selectedSource
        else { return }
        cullingModel.applyRatings(entry.previousRatingsByFileName, in: selectedSource.url)
        rebuildRatingCache()
        lastBurstUndoEntry = nil
        if var result = burstAnalysisResults[entry.groupID] {
            result.reviewState = burstReviewStates[entry.groupID] ?? .none
            burstAnalysisResults[entry.groupID] = result
        }
    }

    // MARK: - Review queue

    var burstReviewQueueCounts: BurstReviewQueueCounts {
        BurstReviewQueuePolicy.counts(for: burstAnalysisResults.values)
    }

    var filteredBurstGroupsForReviewQueue: [BurstGroup] {
        guard burstReviewQueueFilter != .all else { return similarityModel.burstGroups }
        return similarityModel.burstGroups.filter { group in
            guard let result = burstAnalysisResults[group.id] else { return false }
            return BurstReviewQueuePolicy.includes(result, filter: burstReviewQueueFilter)
        }
    }

    func markBurstGroupNeedsReview(groupID: Int) {
        guard !isCreatingSAM3Masks else { return }
        setBurstReviewState(.needsReview, groupID: groupID)
    }

    func markBurstGroupReviewed(groupID: Int) {
        guard !isCreatingSAM3Masks else { return }
        setBurstReviewState(.reviewed, groupID: groupID)
    }

    func deferBurstGroup(groupID: Int) {
        guard !isCreatingSAM3Masks else { return }
        setBurstReviewState(.deferred, groupID: groupID)
    }

    // MARK: - Shared pure helpers

    /// Pick the frame with the highest sharpness score. Returns nil only when
    /// `files` is empty. Kept nonisolated so it can be reused from view-level
    /// cache rebuilds without bouncing to MainActor.
    nonisolated static func sharpestFile(
        in files: [FileItem],
        scores: [UUID: Float],
    ) -> FileItem? {
        files.max(by: { (scores[$0.id] ?? 0) < (scores[$1.id] ?? 0) })
    }

    func burstAnalysisResult(for groupID: Int) -> BurstAnalysisResult? {
        burstAnalysisResults[groupID]
    }

    func burstCandidate(for file: FileItem) -> BurstCandidateScore? {
        guard let groupID = similarityModel.burstGroupLookup[file.id] else { return nil }
        return burstAnalysisResults[groupID]?.candidates.first { $0.fileID == file.id }
    }

    var burstAnalysisTargetFiles: [FileItem] {
        let orderedFiles = burstAnalysisOrderedFiles()
        if !selectedFileIDs.isEmpty {
            return orderedFiles.filter { selectedFileIDs.contains($0.id) }
        }

        if case let .stars(rating) = ratingFilter,
           (2 ... 5).contains(rating) {
            return orderedFiles.filter { getRating(for: $0) == rating }
        }

        return burstOrderedFiles
    }

    func burstAnalysisOrderedFiles() -> [FileItem] {
        let visibleFiles = filteredFiles.isEmpty ? burstOrderedFiles : filteredFiles
        var seenIDs = Set<FileItem.ID>()
        var orderedFiles: [FileItem] = []

        for file in visibleFiles where seenIDs.insert(file.id).inserted {
            orderedFiles.append(file)
        }

        for file in burstOrderedFiles where seenIDs.insert(file.id).inserted {
            orderedFiles.append(file)
        }

        return orderedFiles
    }

    private var burstOrderedFiles: [FileItem] {
        files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func recomputeBurstRankings(files: [FileItem]) {
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let results = BurstRankingEngine.rank(
            groups: similarityModel.burstGroups.filter { $0.fileIDs.count >= 2 },
            filesByID: filesByID,
            scores: sharpnessModel.scores,
            maxScore: sharpnessModel.maxScore,
            saliencyInfo: sharpnessModel.saliencyInfo,
            boundaryEvidence: similarityModel.burstBoundaryEvidence,
            reviewStates: burstReviewStates,
        )
        burstAnalysisResults = Dictionary(uniqueKeysWithValues: results.map { ($0.groupID, $0) })
        applyManualWinnerOverrides(files: files)
    }

    private func groupID(for groupFiles: [FileItem]) -> Int {
        groupFiles.lazy.compactMap { self.similarityModel.burstGroupLookup[$0.id] }.first ?? -1
    }

    private func currentBurstGroupSignature(groupID: Int) -> BurstGroupSignature? {
        guard let catalog = selectedSource?.url,
              let group = similarityModel.burstGroups.first(where: { $0.id == groupID })
        else { return nil }
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        return burstSignature(for: group, filesByID: filesByID, catalog: catalog)
    }

    private func pruneStaleDeepAIReviewResults() {
        deepAIReviewModel.results = deepAIReviewModel.results.filter { groupID, result in
            result.groupSignature == currentBurstGroupSignature(groupID: groupID)
        }
        if let presented = deepAIReviewModel.presentedGroupID,
           deepAIReviewModel.results[presented] == nil {
            deepAIReviewModel.presentedGroupID = nil
        }
    }

    private func canApplyOneClickCulling(groupID: Int) -> Bool {
        guard let result = burstAnalysisResults[groupID] else { return false }
        return result.canApplyOneClickCulling(hasSharpnessScores: !sharpnessModel.scores.isEmpty)
    }

    private struct DeepAIReviewMaskChoice {
        let result: SubjectSegmentationResult
        let geometry: SAM3MaskInventoryEntry
        let usedFallback: Bool
    }

    nonisolated static func deepAIReviewPromptAttempts(
        preset: DeepAIReviewPreset,
        subjectLabel: String?,
    ) -> [SubjectSegmentationPrompt] {
        switch preset {
        case .fullSubject:
            return [.subject]

        case .headFace:
            return deepAIReviewSpecificPromptAttempts(subjectLabel: subjectLabel)

        case .auto:
            let label = subjectLabel?.lowercased() ?? ""
            if label.contains("bird") || label.contains("raptor") || label.contains("wildlife") {
                return [.birdHead, .bird, .subject]
            }
            if label.contains("person") || label.contains("people") || label.contains("human") || label.contains("face") {
                return [.face, .person, .subject]
            }
            if label.contains("deer") {
                return [.animalHead, .deer, .animal, .subject]
            }
            if label.contains("animal") || label.contains("mammal") {
                return [.animalHead, .animal, .subject]
            }
            return [.subject]
        }
    }

    nonisolated static func deepAIReviewSpecificPromptAttempts(
        subjectLabel: String?,
    ) -> [SubjectSegmentationPrompt] {
        let label = subjectLabel?.lowercased() ?? ""
        if label.contains("bird") || label.contains("raptor") || label.contains("wildlife") {
            return [.birdHead, .bird, .subject]
        }
        if label.contains("person") || label.contains("people") || label.contains("human") || label.contains("face") {
            return [.face, .person, .subject]
        }
        if label.contains("deer") {
            return [.animalHead, .deer, .animal, .subject]
        }
        if label.contains("animal") || label.contains("mammal") {
            return [.animalHead, .animal, .subject]
        }
        return [.subject]
    }

    nonisolated static func isUsableDeepAIReviewMask(_ geometry: SAM3MaskInventoryEntry) -> Bool {
        geometry.hasMask &&
            geometry.coverage >= 0.001 &&
            geometry.coverage <= 0.85 &&
            geometry.boundingBox.width > 0.01 &&
            geometry.boundingBox.height > 0.01
    }

    private nonisolated static func deepAIReviewPromptVerified(
        preset: DeepAIReviewPreset,
        maskChoice: DeepAIReviewMaskChoice?,
    ) -> Bool? {
        guard let maskChoice else { return false }
        guard isUsableDeepAIReviewMask(maskChoice.geometry) else { return false }
        switch preset {
        case .fullSubject:
            return maskChoice.result.prompt == .subject

        case .headFace:
            return !maskChoice.usedFallback && [.birdHead, .animalHead, .face].contains(maskChoice.result.prompt)

        case .auto:
            return !maskChoice.usedFallback
        }
    }

    nonisolated static func deepAIReviewConfidence(
        sortedCandidates: [DeepAIReviewCandidate],
    ) -> DeepAIReviewConfidence {
        guard let first = sortedCandidates.first,
              let firstScore = first.deepScore
        else { return .low }
        let secondScore = sortedCandidates.dropFirst().first?.deepScore ?? 0
        let lead = (firstScore - secondScore) / Swift.max(firstScore, 1e-6)
        let hasStrongEvidence = first.maskPromptUsed != nil &&
            first.localDetailScore != nil &&
            first.caution == nil
        if lead >= 0.12, hasStrongEvidence, !first.usedFallbackMask {
            return .high
        }
        if lead >= 0.05 || (hasStrongEvidence && first.usedFallbackMask) {
            return .medium
        }
        return .low
    }

    private func deepAIReviewCandidateFiles(groupFiles: [FileItem], groupID: Int) -> [FileItem] {
        guard groupFiles.count > 12 else { return groupFiles }
        let filesByID = Dictionary(uniqueKeysWithValues: groupFiles.map { ($0.id, $0) })
        let ranked = burstAnalysisResults[groupID]?.candidates.compactMap { filesByID[$0.fileID] } ?? []
        if ranked.count >= 8 {
            return Array(ranked.prefix(8))
        }
        return Array(groupFiles.prefix(8))
    }

    private func bestDeepAIReviewMask(
        for file: FileItem,
        preset: DeepAIReviewPreset,
        subjectLabel: String?,
    ) async -> DeepAIReviewMaskChoice? {
        let attempts = Self.deepAIReviewPromptAttempts(preset: preset, subjectLabel: subjectLabel)
        var fallback: DeepAIReviewMaskChoice?
        for (index, prompt) in attempts.enumerated() {
            guard !Task.isCancelled else { return nil }
            guard let result = await loadOrGenerateDeepAIReviewMask(for: file, prompt: prompt) else { continue }
            let geometry = SAM3MaskInventoryEntry.geometry(
                from: result.mask,
                sourceModificationDate: file.dateModified,
                cacheModificationDate: nil,
                confidence: result.confidence,
            )
            let choice = DeepAIReviewMaskChoice(
                result: result,
                geometry: geometry,
                usedFallback: index > 0,
            )
            if fallback == nil, geometry.hasMask {
                fallback = choice
            }
            if Self.isUsableDeepAIReviewMask(geometry) {
                return choice
            }
        }
        return fallback
    }

    private func loadOrGenerateDeepAIReviewMask(
        for file: FileItem,
        prompt: SubjectSegmentationPrompt,
    ) async -> SubjectSegmentationResult? {
        let diskCache = SharedMemoryCache.shared.sam3MaskDiskCache
        if let cached = await diskCache.load(
            for: file.url,
            fileID: file.id,
            prompt: prompt,
            modelVersion: SAM3SubjectMaskCacheReader.modelVersion,
            inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        ) {
            return cached
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let image = FocusMaskEngine.decodeScoringImage(
            at: file.url,
            maxPixelSize: SAM3SubjectMaskCacheReader.inputMaxSide,
            scoringSource: .embeddedPreview,
            context: context,
        ) else {
            return nil
        }

        do {
            return try await sam3SubjectSegmentationActor.segment(
                image: image,
                fileID: file.id,
                fileURL: file.url,
                prompt: prompt,
            )
        } catch {
            return nil
        }
    }

    private func makeDeepAIReviewResult(
        groupID: Int,
        groupFiles: [FileItem],
        candidateRows: [DeepAIReviewCandidate],
        preset: DeepAIReviewPreset,
    ) -> DeepAIReviewResult {
        let sorted = candidateRows.sorted {
            ($0.deepScore ?? -.infinity) > ($1.deepScore ?? -.infinity)
        }
        let recommended = sorted.first(where: { $0.deepScore?.isFinite == true })
        let confidence = Self.deepAIReviewConfidence(sortedCandidates: sorted)
        let reasons: [String]
        if let recommended {
            var items = ["Strongest deep subject detail"]
            if recommended.afInsideMask == true {
                items.append("AF inside mask")
            }
            if recommended.localDetailScore != nil {
                items.append("local patch evidence")
            }
            reasons = items
        } else {
            reasons = []
        }
        let cautions = Array(Set(candidateRows.compactMap(\.caution))).sorted()
        return DeepAIReviewResult(
            groupID: groupID,
            groupSignature: BurstGroupSignature(files: groupFiles, catalog: selectedSource?.url),
            preset: preset,
            candidates: sorted,
            recommendedFileID: recommended?.fileID,
            confidence: confidence,
            reasons: reasons,
            cautions: cautions,
            timestamp: Date(),
        )
    }

    func manualOverrideWinner(in groupFiles: [FileItem]) -> (file: FileItem, override: BurstWinnerOverride)? {
        guard let selectedSource,
              let override = cullingModel.overrideWinner(for: groupFiles, in: selectedSource.url),
              let file = groupFiles.first(where: { $0.name == override.winnerFileName })
        else { return nil }
        return (file, override)
    }

    private func applyManualWinnerOverrides(files: [FileItem]) {
        guard let selectedSource else { return }
        cullingModel.pruneStaleBurstOverrides(
            validFileNames: Set(files.map(\.name)),
            in: selectedSource.url,
        )

        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        for group in similarityModel.burstGroups {
            let groupFiles = group.fileIDs.compactMap { filesByID[$0] }
            guard let winner = manualOverrideWinner(in: groupFiles)?.file else { continue }
            burstReviewStates[group.id] = .manualWinnerOverride
            guard var result = burstAnalysisResults[group.id] else { continue }
            result.recommendedFileID = winner.id
            result.secondBestFileID = result.candidates.first { $0.fileID != winner.id }?.fileID
            result.reviewState = .manualWinnerOverride
            burstAnalysisResults[group.id] = result
        }
    }

    private func captureUndo(groupID: Int, files: [FileItem]) {
        lastBurstUndoEntry = BurstUndoEntry(
            groupID: groupID,
            previousRatingsByFileName: Dictionary(uniqueKeysWithValues: files.map { ($0.name, getRating(for: $0)) }),
        )
    }

    private func markDecisionApplied(groupID: Int) {
        if burstAnalysisResults[groupID]?.reviewState == .manualWinnerOverride {
            burstReviewStates[groupID] = .manualWinnerOverride
            return
        }
        setBurstReviewState(.decisionApplied, groupID: groupID, persist: false)
        persistBurstReviewStates()
    }

    private func setBurstReviewState(
        _ state: BurstReviewState,
        groupID: Int,
        persist: Bool = true,
    ) {
        burstReviewStates[groupID] = state
        if var result = burstAnalysisResults[groupID] {
            result.reviewState = state
            burstAnalysisResults[groupID] = result
        }
        if persist {
            persistBurstReviewStates()
        }
    }

    private func persistBurstReviewStates() {
        guard let catalog = selectedSource?.url,
              burstAnalysisScopeCatalog == catalog,
              !burstAnalysisScopeFiles.isEmpty
        else { return }
        let snapshot = makeBurstAnalysisCacheSnapshot(
            catalog: catalog,
            files: burstAnalysisScopeFiles,
        )
        Task {
            await burstAnalysisCache.save(snapshot, catalog: catalog)
        }
    }

    private func applyCachedBurstAnalysis(_ snapshot: BurstAnalysisCacheSnapshot, files currentFiles: [FileItem]) {
        similarityModel.applyCachedBurstAnalysis(snapshot)
        sharpnessModel.applyPreloadedScores(
            currentFiles,
            preloadedScores: snapshot.sharpnessScores,
            preloadedSaliency: snapshot.saliencyInfo,
        )
        burstReviewStates = cachedReviewStates(from: snapshot, files: currentFiles)
        burstAnalysisResults = Dictionary(uniqueKeysWithValues: snapshot.results.map { result in
            var updated = result
            updated.reviewState = burstReviewStates[result.groupID] ?? .none
            return (updated.groupID, updated)
        })
        applyManualWinnerOverrides(files: currentFiles)
    }

    func clearLoadedBurstAnalysisForReindex() {
        burstAnalysisTask?.cancel()
        burstAnalysisTask = nil
        burstAnalysisGeneration &+= 1
        burstAnalysisScopeFiles = []
        burstAnalysisScopeCatalog = nil
        burstAnalysisProgress = BurstAnalysisProgress()
        burstAnalysisResults = [:]
        burstReviewStates = [:]
        burstReviewQueueFilter = .all
        activeBurstComparisonGroupID = nil
        lastBurstUndoEntry = nil
        comparisonFileIDs = []
        sharpnessModel.cancelScoring()
        similarityModel.reset()
    }

    private func saveBurstAnalysisCache(catalog: URL, files: [FileItem]) async {
        let snapshot = makeBurstAnalysisCacheSnapshot(catalog: catalog, files: files)
        await burstAnalysisCache.save(snapshot, catalog: catalog)
    }

    private func makeBurstAnalysisCacheSnapshot(
        catalog: URL,
        files: [FileItem],
    ) -> BurstAnalysisCacheSnapshot {
        let preferredBackend = SimilarityScoringModel.preferredEmbeddingBackend(
            useCLIPForSimilarity: SettingsViewModel.shared.useCLIPForSimilarity,
        )
        return BurstAnalysisCacheSnapshot(
            schemaVersion: BurstAnalysisCache.schemaVersion,
            algorithmVersion: BurstGroupingConfig.algorithmVersion,
            catalogPath: catalog.path,
            thumbnailMaxPixelSize: sharpnessModel.effectiveThumbnailMaxPixelSize,
            sharpnessSignature: currentBurstSharpnessSignature,
            similarityGroupingSignature: currentBurstSimilarityGroupingSignature(
                embeddingBackend: preferredBackend,
            ),
            files: files.map {
                BurstAnalysisCacheFile(
                    id: $0.id,
                    path: $0.url.path,
                    size: $0.size,
                    modificationDate: $0.dateModified,
                )
            },
            embeddings: similarityModel.embeddings,
            sharpnessScores: sharpnessModel.scores,
            saliencyInfo: sharpnessModel.saliencyInfo,
            groups: similarityModel.burstGroups,
            boundaryEvidence: similarityModel.burstBoundaryEvidence,
            results: Array(burstAnalysisResults.values).sorted { $0.groupID < $1.groupID },
            reviewStateSnapshots: reviewStateSnapshots(catalog: catalog, files: files),
        )
    }

    func cachedReviewStates(from snapshot: BurstAnalysisCacheSnapshot, files currentFiles: [FileItem]? = nil) -> [Int: BurstReviewState] {
        guard let catalog = selectedSource?.url else { return [:] }
        let filesForLookup = currentFiles ?? files
        return reviewStates(
            from: snapshot.reviewStateSnapshots,
            files: filesForLookup,
            catalog: catalog,
        )
    }

    func reviewStates(
        from snapshots: [BurstReviewStateSnapshot],
        files filesForLookup: [FileItem],
        catalog: URL,
    ) -> [Int: BurstReviewState] {
        let savedStatesBySignature = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.signature, $0.state) },
        )
        let filesByID = Dictionary(uniqueKeysWithValues: filesForLookup.map { ($0.id, $0) })

        var states: [Int: BurstReviewState] = [:]
        for group in similarityModel.burstGroups {
            guard let signature = burstSignature(for: group, filesByID: filesByID, catalog: catalog),
                  let state = savedStatesBySignature[signature],
                  state != .none
            else { continue }
            states[group.id] = state
        }
        return states
    }

    func reviewStateSnapshots(catalog: URL, files: [FileItem]) -> [BurstReviewStateSnapshot] {
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        return similarityModel.burstGroups.compactMap { group in
            guard let state = burstReviewStates[group.id],
                  state != .none,
                  let signature = burstSignature(for: group, filesByID: filesByID, catalog: catalog)
            else { return nil }
            return BurstReviewStateSnapshot(signature: signature, state: state)
        }
    }

    func burstSignature(
        for group: BurstGroup,
        filesByID: [UUID: FileItem],
        catalog: URL?,
    ) -> BurstGroupSignature? {
        let groupFiles = group.fileIDs.compactMap { filesByID[$0] }
        return BurstGroupSignature(files: groupFiles, catalog: catalog)
    }

    private func remapCachedSnapshot(
        _ snapshot: BurstAnalysisCacheSnapshot,
        to currentFiles: [FileItem],
    ) -> BurstAnalysisCacheSnapshot {
        let cachedFilesByID = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.id, $0) })
        let currentByPath = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.url.path, $0.id) })
        var idMap: [UUID: UUID] = [:]
        for (oldID, cachedFile) in cachedFilesByID {
            if let currentID = currentByPath[cachedFile.path] {
                idMap[oldID] = currentID
            }
        }

        func remap(_ id: UUID) -> UUID {
            idMap[id] ?? id
        }

        let groups = snapshot.groups.map { group in
            BurstGroup(id: group.id, fileIDs: group.fileIDs.map(remap))
        }
        let evidence = snapshot.boundaryEvidence.map { item in
            BurstBoundaryEvidence(
                previousID: remap(item.previousID),
                currentID: remap(item.currentID),
                visualDistance: item.visualDistance,
                timeGapSeconds: item.timeGapSeconds,
                focalLengthDelta: item.focalLengthDelta,
                exposureChanged: item.exposureChanged,
                cameraChanged: item.cameraChanged,
                lensChanged: item.lensChanged,
                startsNewGroup: item.startsNewGroup,
                reasons: item.reasons,
            )
        }
        let results = snapshot.results.map { result in
            BurstAnalysisResult(
                groupID: result.groupID,
                fileIDs: result.fileIDs.map(remap),
                candidates: result.candidates.map { candidate in
                    BurstCandidateScore(
                        fileID: remap(candidate.fileID),
                        overallScore: candidate.overallScore,
                        sharpnessComponent: candidate.sharpnessComponent,
                        burstRelativeSharpnessComponent: candidate.burstRelativeSharpnessComponent,
                        focusPointComponent: candidate.focusPointComponent,
                        saliencyComponent: candidate.saliencyComponent,
                        metadataComponent: candidate.metadataComponent,
                        confidence: candidate.confidence,
                        reasons: candidate.reasons,
                        cautions: candidate.cautions,
                    )
                },
                recommendedFileID: result.recommendedFileID.map(remap),
                secondBestFileID: result.secondBestFileID.map(remap),
                confidence: result.confidence,
                reviewState: result.reviewState,
                isSafeForOneClickCulling: result.isSafeForOneClickCulling,
                reasons: result.reasons,
                cautions: result.cautions,
            )
        }

        return BurstAnalysisCacheSnapshot(
            schemaVersion: snapshot.schemaVersion,
            algorithmVersion: snapshot.algorithmVersion,
            catalogPath: snapshot.catalogPath,
            thumbnailMaxPixelSize: snapshot.thumbnailMaxPixelSize,
            sharpnessSignature: snapshot.sharpnessSignature,
            similarityGroupingSignature: snapshot.similarityGroupingSignature,
            files: currentFiles.map {
                BurstAnalysisCacheFile(id: $0.id, path: $0.url.path, size: $0.size, modificationDate: $0.dateModified)
            },
            embeddings: Dictionary(uniqueKeysWithValues: snapshot.embeddings.compactMap { oldID, data in
                guard let currentID = idMap[oldID] else { return nil }
                return (currentID, data)
            }),
            sharpnessScores: Dictionary(uniqueKeysWithValues: snapshot.sharpnessScores.compactMap { oldID, score in
                guard let currentID = idMap[oldID] else { return nil }
                return (currentID, score)
            }),
            saliencyInfo: Dictionary(uniqueKeysWithValues: snapshot.saliencyInfo.compactMap { oldID, info in
                guard let currentID = idMap[oldID] else { return nil }
                return (currentID, info)
            }),
            groups: groups,
            boundaryEvidence: evidence,
            results: results,
            reviewStateSnapshots: snapshot.reviewStateSnapshots,
        )
    }

    private var currentBurstSharpnessSignature: BurstSharpnessSignature {
        sharpnessModel.scoringSignature
    }

    private func currentBurstSimilarityGroupingSignature(
        embeddingBackend: SimilarityEmbeddingBackend,
    ) -> BurstSimilarityGroupingSignature {
        let modelURL = embeddingBackend == .clip ? CLIPModelResourceManager.installedModelURL() : nil
        return BurstSimilarityGroupingSignature(
            embeddingBackend: embeddingBackend,
            embeddingEnvelopeVersion: SimilarityEmbeddingEnvelope.currentVersion,
            clipModelIdentifier: CLIPModelResourceManager.cacheIdentifier(for: modelURL),
            groupingConfig: BurstGroupingConfig(
                visualDistanceThreshold: similarityModel.burstSensitivity,
            ),
        )
    }
}
