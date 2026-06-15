//
//  SimilarityScoringModel.swift
//  RawCull
//

import Foundation
import ImageIO
import Observation
import OSLog
import RawCullCore
import RawParserKit
import Vision

// MARK: - Constants

/// Blend weight applied to the saliency-subject mismatch penalty.
/// 0 = ignore subject mismatch, 1 = equal weight with visual distance.
/// Keep small so the visual embedding remains the dominant signal.
private let kSubjectMismatchPenalty: Float = 0.10
private let kMinimumSamplesBeforeEstimation = 10
private let kEstimationWindowSize = 10

// MARK: - Embeddings

nonisolated enum SimilarityEmbeddingBackend: String, Codable {
    case clip
    case visionFeaturePrint

    var displayName: String {
        switch self {
        case .clip: "CLIP"
        case .visionFeaturePrint: "Vision"
        }
    }
}

nonisolated struct SimilarityEmbeddingEnvelope: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let backend: SimilarityEmbeddingBackend
    let dimensions: Int
    let values: [Float]

    init(
        version: Int = Self.currentVersion,
        backend: SimilarityEmbeddingBackend,
        dimensions: Int,
        values: [Float],
    ) {
        self.version = version
        self.backend = backend
        self.dimensions = dimensions
        self.values = values
    }

    static func clip(_ values: [Float]) -> Self {
        let normalizedValues = normalized(values)
        return Self(
            backend: .clip,
            dimensions: normalizedValues.count,
            values: normalizedValues,
        )
    }

    static func encodeCLIP(_ values: [Float]) -> Data? {
        try? JSONEncoder().encode(clip(values))
    }

    static func decode(from data: Data) -> Self? {
        guard let envelope = try? JSONDecoder().decode(Self.self, from: data),
              envelope.version == Self.currentVersion,
              envelope.dimensions == envelope.values.count,
              !envelope.values.isEmpty
        else {
            return nil
        }
        return envelope
    }

    static func normalized(_ values: [Float]) -> [Float] {
        let magnitude = sqrt(values.reduce(Float(0)) { partial, value in
            partial + value * value
        })
        guard magnitude.isFinite, magnitude > 0 else {
            return values
        }
        return values.map { $0 / magnitude }
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        let left = normalized(lhs)
        let right = normalized(rhs)
        let dot = zip(left, right).reduce(Float(0)) { partial, pair in
            partial + pair.0 * pair.1
        }
        guard dot.isFinite else { return nil }
        return max(0, min(2, 1 - dot))
    }
}

nonisolated struct SimilarityIndexResult {
    let embeddingData: Data
    let clipLabel: String?
    let clipConfidence: Float?
}

// MARK: - Model

@Observable @MainActor
final class SimilarityScoringModel {
    // MARK: State

    /// Archived VNFeaturePrintObservation data keyed by FileItem.id.
    /// Stored as NSKeyedArchiver-encoded Data to avoid holding many
    /// large objects alive simultaneously.
    var embeddings: [UUID: Data] = [:]

    /// Whole-image zero-shot labels produced by CLIP while indexing.
    var clipLabels: [UUID: String] = [:]
    var clipLabelConfidences: [UUID: Float] = [:]

    /// Raw distances from the current anchor image (lower = more similar).
    /// Populated by rankSimilar(to:using:saliencyInfo:).
    var distances: [UUID: Float] = [:]

    /// UUID of the image used as the similarity anchor.
    var anchorFileID: UUID?

    // MARK: Indexing progress

    var isIndexing: Bool = false
    var indexingProgress: Int = 0
    var indexingTotal: Int = 0
    var indexingEstimatedSeconds: Int = 0

    // MARK: Sort flag

    /// When true, applyFilters sorts the file list by ascending distance.
    var sortBySimilarity: Bool = false

    /// Backend selected for the latest indexing pass.
    var embeddingBackend: SimilarityEmbeddingBackend = .visionFeaturePrint

    var usesCLIPEmbeddings: Bool {
        embeddingBackend == .clip
    }

    /// Counts of the actual embedding payloads currently held in memory. These
    /// make CLIP fallback visible when the selected backend differs from storage.
    var clipEmbeddingCount: Int = 0
    var visionEmbeddingCount: Int = 0

    var embeddingBackendStatusText: String {
        let storedCount = clipEmbeddingCount + visionEmbeddingCount
        guard storedCount > 0 else {
            return "Backend: \(embeddingBackend.displayName) ready"
        }
        if clipEmbeddingCount == storedCount {
            return "Backend: CLIP"
        }
        if visionEmbeddingCount == storedCount {
            return embeddingBackend == .clip ? "Backend: Vision fallback" : "Backend: Vision"
        }
        return "Backend: mixed"
    }

    var embeddingBackendDetailText: String {
        let storedCount = clipEmbeddingCount + visionEmbeddingCount
        guard storedCount > 0 else {
            return embeddingBackend == .clip
                ? "CLIP is enabled and will be used for the next similarity index."
                : "Vision feature prints will be used for the next similarity index."
        }
        return "\(clipEmbeddingCount) CLIP, \(visionEmbeddingCount) Vision embeddings stored."
    }

    // MARK: Burst grouping

    /// Burst groups computed by sequential distance clustering.
    var burstGroups: [BurstGroup] = []
    /// Quick lookup: fileID → group id.
    var burstGroupLookup: [UUID: Int] = [:]
    /// Distance threshold for burst clustering. Lower = tighter groups.
    var burstSensitivity: Float = 0.25
    /// When true, the grid renders burst group section headers.
    var burstModeActive: Bool = false
    /// True while groupBursts() is running.
    var isGrouping: Bool = false
    /// Per-boundary evidence from the latest burst grouping run.
    var burstBoundaryEvidence: [BurstBoundaryEvidence] = []

    // MARK: Private

    @ObservationIgnored private var _indexingTask: Task<Void, Never>?
    @ObservationIgnored private var _groupingTask: Task<BurstGroupingOutput?, Never>?
    @ObservationIgnored private var _groupingGeneration: Int = 0
    @ObservationIgnored private var _adjacentDistanceCache: [String: Float] = [:]
    @ObservationIgnored private var _adjacentDistanceCacheSignature: Int = 0

    // MARK: - Public API

    func reset() {
        cancelIndexing()
        _groupingTask?.cancel()
        _groupingTask = nil
        embeddings = [:]
        clipLabels = [:]
        clipLabelConfidences = [:]
        clipEmbeddingCount = 0
        visionEmbeddingCount = 0
        distances = [:]
        anchorFileID = nil
        sortBySimilarity = false
        embeddingBackend = .visionFeaturePrint
        burstGroups = []
        burstGroupLookup = [:]
        burstBoundaryEvidence = []
        burstModeActive = false
        isGrouping = false
        _groupingGeneration = 0
        _adjacentDistanceCache = [:]
        _adjacentDistanceCacheSignature = 0
    }

    func cancelIndexing() {
        _indexingTask?.cancel()
        _indexingTask = nil
        isIndexing = false
        indexingProgress = 0
        indexingTotal = 0
        indexingEstimatedSeconds = 0
    }

    func hasCurrentEmbeddings(
        for files: [FileItem],
        backend: SimilarityEmbeddingBackend,
    ) -> Bool {
        Self.hasCurrentEmbeddings(
            files: files,
            embeddings: embeddings,
            backend: backend,
        )
    }

    /// Compute similarity embeddings for all files using thumbnail-resolution
    /// images (same thumbnail size used by sharpness scoring). CLIP is preferred
    /// when installed; Vision feature prints are used as the fallback backend.
    /// Already-embedded files are skipped for efficiency.
    func indexFiles(_ files: [FileItem], thumbnailMaxPixelSize: Int = 512) async {
        guard !files.isEmpty else { return }

        isIndexing = true
        indexingProgress = 0
        indexingTotal = files.count
        indexingEstimatedSeconds = 0
        defer { isIndexing = false }

        await SettingsViewModel.shared.ensureLoaded()
        let preferredBackend = Self.preferredEmbeddingBackend(
            useCLIPForSimilarity: SettingsViewModel.shared.useCLIPForSimilarity,
        )
        embeddingBackend = preferredBackend
        let clipProvider = preferredBackend == .clip ? CoreAICLIPProvider() : nil
        Logger.process.info("SimilarityScoringModel: indexing similarity with \(preferredBackend.displayName) backend")

        // Separate files that need embedding from those already done for the active backend.
        let toIndex = files.filter { file in
            guard let data = embeddings[file.id] else { return true }
            return Self.embeddingBackend(for: data) != preferredBackend
        }
        if toIndex.isEmpty {
            indexingProgress = files.count
            return
        }
        indexingTotal = toIndex.count

        let thumbSize = thumbnailMaxPixelSize
        var iterator = toIndex.makeIterator()
        var active = 0
        let maxConcurrent = 4

        let workTask = Task {
            await withTaskGroup(of: (UUID, SimilarityIndexResult?).self) { group in
                while active < maxConcurrent, let file = iterator.next() {
                    let url = file.url
                    let id = file.id
                    let provider = clipProvider
                    group.addTask(priority: .userInitiated) {
                        let result = await Self.computeEmbedding(
                            url: url,
                            maxPixelSize: thumbSize,
                            preferredBackend: preferredBackend,
                            clipProvider: provider,
                        )
                        return (id, result)
                    }
                    active += 1
                }

                var localResults: [UUID: SimilarityIndexResult] = [:]
                var completedCount = 0
                var completionTimes: [TimeInterval] = []
                var lastCompletionTime: Date?

                for await (id, result) in group {
                    active -= 1
                    guard !Task.isCancelled else { break }

                    if let result { localResults[id] = result }
                    completedCount += 1
                    self.indexingProgress = completedCount

                    let now = Date()
                    if let lastCompletionTime {
                        completionTimes.append(now.timeIntervalSince(lastCompletionTime))
                    }
                    lastCompletionTime = now

                    if completedCount >= kMinimumSamplesBeforeEstimation, !completionTimes.isEmpty {
                        let recentTimes = completionTimes.suffix(min(kEstimationWindowSize, completionTimes.count))
                        let avgSecondsPerCompletion = recentTimes.reduce(0, +) / Double(recentTimes.count)
                        let remainingItems = toIndex.count - completedCount
                        self.indexingEstimatedSeconds = Swift.max(0, Int(avgSecondsPerCompletion * Double(remainingItems)))
                    }

                    if let file = iterator.next() {
                        let url = file.url
                        let id = file.id
                        let provider = clipProvider
                        group.addTask(priority: .userInitiated) {
                            let result = await Self.computeEmbedding(
                                url: url,
                                maxPixelSize: thumbSize,
                                preferredBackend: preferredBackend,
                                clipProvider: provider,
                            )
                            return (id, result)
                        }
                        active += 1
                    }
                }

                guard !Task.isCancelled else { return }
                // Merge newly computed embeddings with any pre-existing ones.
                for (id, result) in localResults {
                    self.embeddings[id] = result.embeddingData
                    if let label = result.clipLabel {
                        self.clipLabels[id] = label
                    } else {
                        self.clipLabels[id] = nil
                    }
                    if let confidence = result.clipConfidence {
                        self.clipLabelConfidences[id] = confidence
                    } else {
                        self.clipLabelConfidences[id] = nil
                    }
                }
                self.refreshEmbeddingBackendCounts()
                Logger.process.info(
                    "SimilarityScoringModel: indexed \(localResults.count)/\(toIndex.count) files using \(preferredBackend.displayName); stored \(self.clipEmbeddingCount) CLIP and \(self.visionEmbeddingCount) Vision embeddings",
                )
            }
        }

        _indexingTask = workTask
        await workTask.value
        _indexingTask = nil
        guard !workTask.isCancelled else { return }

        indexingProgress = 0
        indexingTotal = 0
        indexingEstimatedSeconds = 0
    }

    /// Compute and store distances from `anchorID` to all other embedded images.
    /// Applies a small saliency-subject mismatch penalty when both images have
    /// subject labels and the labels differ.
    ///
    /// The heavy unarchiving + distance loop runs on the cooperative thread pool
    /// (via Task.detached) to avoid blocking the main thread on large catalogs.
    ///
    /// - Parameters:
    ///   - anchorID: The reference image's UUID.
    ///   - files: The full file list (used only to look up saliency info ordering).
    ///   - saliencyInfo: Optional subject labels from sharpness scoring.
    func rankSimilar(
        to anchorID: UUID,
        using _: [FileItem],
        saliencyInfo: [UUID: SaliencyInfo] = [:],
    ) async {
        guard let anchorData = embeddings[anchorID] else {
            distances = [:]
            anchorFileID = nil
            sortBySimilarity = false
            return
        }

        let anchorLabel = saliencyInfo[anchorID]?.subjectLabel
        // Snapshot both dicts before hopping off the main actor — both are [UUID: Sendable].
        let snapshot = embeddings
        // Capture as a local so the file-scope constant (implicitly @MainActor under
        // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) is safe to use inside Task.detached.
        let mismatchPenalty = kSubjectMismatchPenalty

        let result: [UUID: Float]? = await Task.detached(priority: .userInitiated) {
            guard let anchor = Self.decodedEmbedding(from: anchorData) else {
                Logger.process.warning("SimilarityScoringModel: failed to decode anchor embedding")
                return nil
            }

            var r: [UUID: Float] = [:]
            for (id, data) in snapshot where id != anchorID {
                guard let candidate = Self.decodedEmbedding(from: data),
                      var d = Self.distance(from: anchor, to: candidate)
                else { continue }

                // Apply a small saliency-subject mismatch penalty so images of a
                // different subject type are ranked slightly lower, while keeping
                // the visual embedding as the dominant signal.
                //   d_out = d_visual + kSubjectMismatchPenalty    (0.10, additive
                //   in VNFeaturePrintObservation distance space — typical d ≈ 0.3–1.2
                //   between unrelated images, so +0.10 is meaningful but not dominant).
                if let al = anchorLabel, let cl = saliencyInfo[id]?.subjectLabel, al != cl {
                    d += mismatchPenalty
                }

                r[id] = d
            }
            return r
        }.value

        guard let result else {
            distances = [:]
            anchorFileID = nil
            sortBySimilarity = false
            return
        }

        anchorFileID = anchorID
        distances = result
        sortBySimilarity = true
    }

    // MARK: - Burst grouping

    /// Cluster `files` into burst groups using a sequential O(n) distance pass.
    /// `files` must be sorted by filename (= shot order) before calling.
    /// Sets `burstModeActive = true` on completion.
    ///
    /// Cancels any in-flight grouping work at the top so a dragging slider
    /// does not spawn multiple concurrent unarchive passes over the full
    /// embedding snapshot — otherwise the cooperative thread pool saturates
    /// and the UI beach-balls on large catalogs.
    func groupBursts(files: [FileItem]) async {
        guard !files.isEmpty else {
            _groupingTask?.cancel()
            _groupingTask = nil
            burstGroups = []
            burstGroupLookup = [:]
            burstBoundaryEvidence = []
            burstModeActive = true
            return
        }

        _groupingTask?.cancel()
        _groupingTask = nil

        isGrouping = true
        _groupingGeneration &+= 1
        let myGeneration = _groupingGeneration

        let threshold = burstSensitivity
        let snapshot = embeddings // [UUID: Data], Sendable
        let config = BurstGroupingConfig(visualDistanceThreshold: threshold)
        let signature = Self.cacheSignature(files: files, embeddings: snapshot)
        let cachedAdjacentDistances = _adjacentDistanceCacheSignature == signature ? _adjacentDistanceCache : [:]

        let work = Task.detached(priority: .userInitiated) { () -> BurstGroupingOutput? in
            let adjacentDistances = Self.computeAdjacentDistances(
                files: files,
                embeddings: snapshot,
                cached: cachedAdjacentDistances,
            )
            guard !Task.isCancelled else { return nil }
            return BurstGroupingEngine.group(
                files: files,
                adjacentDistances: adjacentDistances,
                config: config,
            )
        }
        _groupingTask = work

        let output = await work.value

        // Drop our handle only if we're still the current job.
        if _groupingTask == work { _groupingTask = nil }

        // Only the latest generation's result is allowed to touch state, and
        // we flip isGrouping off here (not via defer) so a cancelled run does
        // not briefly clear the indicator while a newer run is still active.
        guard _groupingGeneration == myGeneration else { return }
        isGrouping = false

        guard let output else { return }

        var lookup: [UUID: Int] = [:]
        for group in output.groups {
            for id in group.fileIDs {
                lookup[id] = group.id
            }
        }
        burstGroups = output.groups
        burstGroupLookup = lookup
        burstBoundaryEvidence = output.boundaryEvidence
        _adjacentDistanceCache = Dictionary(
            uniqueKeysWithValues: output.boundaryEvidence.compactMap { evidence in
                guard let distance = evidence.visualDistance else { return nil }
                return (BurstPairKey.cacheKey(previousID: evidence.previousID, currentID: evidence.currentID), distance)
            },
        )
        _adjacentDistanceCacheSignature = signature
        burstModeActive = true
        Logger.process.debugMessageOnly("SimilarityScoringModel: \(burstGroups.count) burst groups from \(files.count) files (threshold \(threshold))")
    }

    func applyCachedBurstAnalysis(_ snapshot: BurstAnalysisCacheSnapshot) {
        embeddings = snapshot.embeddings
        clipLabels = [:]
        clipLabelConfidences = [:]
        refreshEmbeddingBackendCounts()
        burstGroups = snapshot.groups
        burstBoundaryEvidence = snapshot.boundaryEvidence
        burstGroupLookup = Dictionary(uniqueKeysWithValues: snapshot.groups.flatMap { group in
            group.fileIDs.map { ($0, group.id) }
        })
        _adjacentDistanceCache = Dictionary(
            uniqueKeysWithValues: snapshot.boundaryEvidence.compactMap { evidence in
                guard let distance = evidence.visualDistance else { return nil }
                return (BurstPairKey.cacheKey(previousID: evidence.previousID, currentID: evidence.currentID), distance)
            },
        )
        _adjacentDistanceCacheSignature = 0
        burstModeActive = !snapshot.groups.isEmpty
    }

    private func refreshEmbeddingBackendCounts() {
        let counts = Self.embeddingBackendCounts(for: embeddings.values)
        clipEmbeddingCount = counts.clip
        visionEmbeddingCount = counts.vision
    }

    // MARK: - Static helpers (nonisolated, used from detached tasks)

    /// Decode a thumbnail from a Sony ARW file and compute a similarity embedding.
    /// Returns a typed CLIP envelope and label when CLIP succeeds, otherwise a
    /// legacy archived VNFeaturePrintObservation fallback.
    nonisolated static func computeEmbedding(
        url: URL,
        maxPixelSize: Int,
        preferredBackend: SimilarityEmbeddingBackend = preferredEmbeddingBackend(),
        clipProvider: CoreAICLIPProvider? = nil,
    ) async -> SimilarityIndexResult? {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = await decodeRawParserKitThumbnail(at: url, maxPixelSize: maxPixelSize)
                ?? decodeThumbnail(at: url, maxPixelSize: maxPixelSize)
            else {
                Logger.process.debugMessageOnly("SimilarityScoringModel: could not decode image at \(url.lastPathComponent)")
                return nil
            }

            if preferredBackend == .clip, let clipProvider {
                do {
                    let analysis = try await clipProvider.imageAnalysis(for: cgImage)
                    if let data = SimilarityEmbeddingEnvelope.encodeCLIP(analysis.embedding) {
                        return SimilarityIndexResult(
                            embeddingData: data,
                            clipLabel: analysis.label,
                            clipConfidence: analysis.confidence,
                        )
                    }
                } catch {
                    Logger.process.warning("SimilarityScoringModel: CLIP embedding failed for \(url.lastPathComponent), falling back to Vision: \(String(describing: error))")
                }
            }

            guard let data = visionFeaturePrintEmbedding(for: cgImage, fileName: url.lastPathComponent) else {
                return nil
            }
            return SimilarityIndexResult(
                embeddingData: data,
                clipLabel: nil,
                clipConfidence: nil,
            )
        }.value
    }

    nonisolated static func computeAdjacentDistances(
        files: [FileItem],
        embeddings: [UUID: Data],
        cached: [String: Float] = [:],
    ) -> [String: Float] {
        guard files.count > 1 else { return [:] }

        var distances = cached
        var observations: [UUID: VNFeaturePrintObservation] = [:]

        for index in files.indices.dropFirst() {
            if index & 0x3F == 0, Task.isCancelled { return distances }
            let previousID = files[index - 1].id
            let currentID = files[index].id
            let key = BurstPairKey.cacheKey(previousID: previousID, currentID: currentID)
            if distances[key] != nil { continue }

            guard let previous = decodedEmbedding(for: previousID, embeddings: embeddings, observations: &observations),
                  let current = decodedEmbedding(for: currentID, embeddings: embeddings, observations: &observations),
                  let distance = distance(from: previous, to: current)
            else { continue }
            distances[key] = distance
        }

        return distances
    }

    nonisolated static func preferredEmbeddingBackend(
        clipModelURL: URL? = CLIPModelResourceManager.installedModelURL(),
        useCLIPForSimilarity: Bool = false,
    ) -> SimilarityEmbeddingBackend {
        useCLIPForSimilarity && clipModelURL != nil ? .clip : .visionFeaturePrint
    }

    nonisolated static func embeddingBackend(for data: Data) -> SimilarityEmbeddingBackend {
        SimilarityEmbeddingEnvelope.decode(from: data)?.backend ?? .visionFeaturePrint
    }

    nonisolated static func embeddingBackendCounts(
        for dataSequence: some Sequence<Data>,
    ) -> (clip: Int, vision: Int) {
        var clip = 0
        var vision = 0
        for data in dataSequence {
            switch embeddingBackend(for: data) {
            case .clip:
                clip += 1

            case .visionFeaturePrint:
                vision += 1
            }
        }
        return (clip, vision)
    }

    nonisolated static func hasCurrentEmbeddings(
        files: [FileItem],
        embeddings: [UUID: Data],
        backend: SimilarityEmbeddingBackend,
    ) -> Bool {
        guard !files.isEmpty else { return false }
        return files.allSatisfy { file in
            guard let data = embeddings[file.id] else { return false }
            return embeddingBackend(for: data) == backend
        }
    }

    nonisolated static func distance(from lhs: DecodedSimilarityEmbedding, to rhs: DecodedSimilarityEmbedding) -> Float? {
        switch (lhs, rhs) {
        case let (.clip(left), .clip(right)):
            return SimilarityEmbeddingEnvelope.cosineDistance(left, right)

        case let (.vision(left), .vision(right)):
            var distance: Float = 0
            guard (try? left.computeDistance(&distance, to: right)) != nil else { return nil }
            return distance

        case (.clip, .vision), (.vision, .clip):
            return nil
        }
    }

    nonisolated static func decodedEmbedding(from data: Data) -> DecodedSimilarityEmbedding? {
        if let envelope = SimilarityEmbeddingEnvelope.decode(from: data),
           envelope.backend == .clip {
            return .clip(envelope.values)
        }
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data,
        ) else {
            return nil
        }
        return .vision(observation)
    }

    private nonisolated static func decodedEmbedding(
        for id: UUID,
        embeddings: [UUID: Data],
        observations: inout [UUID: VNFeaturePrintObservation],
    ) -> DecodedSimilarityEmbedding? {
        guard let data = embeddings[id] else { return nil }
        if let envelope = SimilarityEmbeddingEnvelope.decode(from: data),
           envelope.backend == .clip {
            return .clip(envelope.values)
        }
        if let observation = observations[id] {
            return .vision(observation)
        }
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data,
        )
        else { return nil }
        observations[id] = observation
        return .vision(observation)
    }

    nonisolated static func cacheSignature(files: [FileItem], embeddings: [UUID: Data]) -> Int {
        var hasher = Hasher()
        hasher.combine(files.count)
        for file in files {
            hasher.combine(file.id)
            guard let data = embeddings[file.id] else {
                hasher.combine(0)
                continue
            }
            hasher.combine(data.count)
            hasher.combine(data)
            hasher.combine(embeddingBackend(for: data).rawValue)
        }
        return hasher.finalize()
    }

    /// Decode an embedded thumbnail from a Sony ARW via CGImageSource.
    private nonisolated static func decodeThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    /// Prefer RawParserKit's registered vendor extractor. It owns embedded-JPEG
    /// fallbacks for RAW formats that ImageIO cannot decode directly.
    private nonisolated static func decodeRawParserKitThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let format = RawFormatRegistry.format(for: url) else { return nil }
        return try? await format.extractThumbnail(
            from: url,
            maxDimension: CGFloat(maxPixelSize),
            qualityCost: 4,
        )
    }

    private nonisolated static func visionFeaturePrintEmbedding(
        for cgImage: CGImage,
        fileName: String,
    ) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger.process.warning("SimilarityScoringModel: Vision feature-print request failed for \(fileName): \(error)")
            return nil
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}

nonisolated enum DecodedSimilarityEmbedding {
    case clip([Float])
    case vision(VNFeaturePrintObservation)
}
