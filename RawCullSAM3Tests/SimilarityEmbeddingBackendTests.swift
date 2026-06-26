import Foundation
import RawCullCore
@testable import RawCullSAM3
import Testing

@MainActor
struct SimilarityEmbeddingBackendTests {
    @Test
    func `CLIP cosine distance is zero for identical vectors`() throws {
        let distance = try #require(SimilarityEmbeddingEnvelope.cosineDistance([1, 0, 0], [1, 0, 0]))

        #expect(abs(distance - 0) < 0.0001)
    }

    @Test
    func `CLIP cosine distance is one for orthogonal vectors`() throws {
        let distance = try #require(SimilarityEmbeddingEnvelope.cosineDistance([1, 0, 0], [0, 1, 0]))

        #expect(abs(distance - 1) < 0.0001)
    }

    @Test
    func `CLIP embedding envelope round trips and reports backend`() throws {
        let data = try #require(SimilarityEmbeddingEnvelope.encodeCLIP([3, 4]))
        let envelope = try #require(SimilarityEmbeddingEnvelope.decode(from: data))

        #expect(envelope.backend == .clip)
        #expect(envelope.dimensions == 2)
        #expect(abs(envelope.values[0] - 0.6) < 0.0001)
        #expect(abs(envelope.values[1] - 0.8) < 0.0001)
        #expect(SimilarityScoringModel.embeddingBackend(for: data) == .clip)
    }

    @Test
    func `preferred backend reports CLIP only when model URL is available`() {
        #expect(SimilarityScoringModel.preferredEmbeddingBackend(clipModelURL: URL(fileURLWithPath: "/tmp/CLIP"), useCLIPForSimilarity: true) == .clip)
        #expect(SimilarityScoringModel.preferredEmbeddingBackend(clipModelURL: URL(fileURLWithPath: "/tmp/CLIP"), useCLIPForSimilarity: false) == .visionFeaturePrint)
        #expect(SimilarityScoringModel.preferredEmbeddingBackend(clipModelURL: nil, useCLIPForSimilarity: true) == .visionFeaturePrint)
    }

    @Test
    func `corrupt embedding data is ignored`() {
        let corrupt = Data("not json and not a vision archive".utf8)

        #expect(SimilarityEmbeddingEnvelope.decode(from: corrupt) == nil)
        #expect(SimilarityScoringModel.decodedEmbedding(from: corrupt) == nil)
        #expect(SimilarityScoringModel.embeddingBackend(for: corrupt) == .visionFeaturePrint)
    }

    @Test
    func `rankSimilar orders lower CLIP distance first`() async throws {
        let anchor = makeSimilarityTestFile("anchor.ARW")
        let near = makeSimilarityTestFile("near.ARW")
        let far = makeSimilarityTestFile("far.ARW")
        let missing = makeSimilarityTestFile("missing.ARW")
        let model = SimilarityScoringModel()
        model.embeddings = try [
            anchor.id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([1, 0, 0])),
            near.id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.95, 0.05, 0])),
            far.id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0, 1, 0]))
        ]

        await model.rankSimilar(to: anchor.id, using: [anchor, near, far, missing])

        #expect(model.anchorFileID == anchor.id)
        #expect(model.sortBySimilarity)
        #expect(model.distances[near.id] != nil)
        #expect(model.distances[far.id] != nil)
        #expect(model.distances[missing.id] == nil)
        #expect((model.distances[near.id] ?? 2) < (model.distances[far.id] ?? 0))
    }

    @Test
    func `rankSimilar with unknown anchor clears state`() async {
        let model = SimilarityScoringModel()
        model.distances = [UUID(): 0.2]
        model.anchorFileID = UUID()
        model.sortBySimilarity = true

        await model.rankSimilar(to: UUID(), using: [])

        #expect(model.distances.isEmpty)
        #expect(model.anchorFileID == nil)
        #expect(!model.sortBySimilarity)
    }

    @Test
    func `embedding freshness requires every current file id for selected backend`() throws {
        let current = [makeSimilarityTestFile("one.ARW"), makeSimilarityTestFile("two.ARW")]
        let stale = makeSimilarityTestFile("stale.ARW")
        let embeddings = try [
            current[0].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([1, 0])),
            stale.id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0, 1]))
        ]

        #expect(!SimilarityScoringModel.hasCurrentEmbeddings(
            files: current,
            embeddings: embeddings,
            backend: .clip,
        ))
    }

    @Test
    func `one non CLIP result downgrades the whole indexing pass`() throws {
        let clipID = UUID()
        let visionID = UUID()
        let clipData = try #require(SimilarityEmbeddingEnvelope.encodeCLIP([1, 0]))
        let visionData = Data("vision-placeholder".utf8)
        let results = [
            clipID: SimilarityIndexResult(embeddingData: clipData, clipLabel: nil, clipConfidence: nil),
            visionID: SimilarityIndexResult(embeddingData: visionData, clipLabel: nil, clipConfidence: nil),
        ]

        #expect(SimilarityScoringModel.requiresVisionFallback(
            preferredBackend: .clip,
            expectedCount: 2,
            results: results,
        ))
        #expect(!SimilarityScoringModel.requiresVisionFallback(
            preferredBackend: .visionFeaturePrint,
            expectedCount: 2,
            results: results,
        ))
    }

    @Test
    func `successful CLIP indexing stores embeddings without labels`() async throws {
        let files = [
            makeSimilarityTestFile("one.ARW"),
            makeSimilarityTestFile("two.ARW")
        ]
        let model = SimilarityScoringModel()

        await model.indexFiles(
            files,
            preferredBackendOverride: .clip,
            embeddingComputer: { url, _, backend, _ in
                #expect(backend == .clip)
                let value: Float = url.lastPathComponent == "one.ARW" ? 1 : 2
                return SimilarityIndexResult(
                    embeddingData: SimilarityEmbeddingEnvelope.encodeCLIP([value, 0]) ?? Data(),
                    clipLabel: nil,
                    clipConfidence: nil,
                )
            },
        )

        #expect(model.embeddingBackend == .clip)
        #expect(!model.didFallbackFromCLIP)
        #expect(model.clipEmbeddingCount == files.count)
        #expect(model.visionEmbeddingCount == 0)
        #expect(model.clipLabels.isEmpty)
        #expect(model.isIndexing == false)
        #expect(model.indexingProgress == 0)
        #expect(model.indexingTotal == 0)
    }

    @Test
    func `incomplete CLIP pass recomputes full scope with Vision`() async throws {
        let files = [
            makeSimilarityTestFile("one.ARW"),
            makeSimilarityTestFile("two.ARW"),
            makeSimilarityTestFile("three.ARW")
        ]
        let tracker = SimilarityIndexingTestTracker()
        let model = SimilarityScoringModel()

        await model.indexFiles(
            files,
            preferredBackendOverride: .clip,
            embeddingComputer: { url, _, backend, _ in
                await tracker.record(url: url, backend: backend)
                if backend == .clip, url.lastPathComponent == "two.ARW" {
                    return nil
                }
                if backend == .clip {
                    return SimilarityIndexResult(
                        embeddingData: SimilarityEmbeddingEnvelope.encodeCLIP([1, 0]) ?? Data(),
                        clipLabel: nil,
                        clipConfidence: nil,
                    )
                }
                return SimilarityIndexResult(
                    embeddingData: Data("vision-\(url.lastPathComponent)".utf8),
                    clipLabel: nil,
                    clipConfidence: nil,
                )
            },
        )

        let visionFiles = await tracker.fileNames(for: .visionFeaturePrint)
        #expect(model.embeddingBackend == .visionFeaturePrint)
        #expect(model.didFallbackFromCLIP)
        #expect(model.clipEmbeddingCount == 0)
        #expect(model.visionEmbeddingCount == files.count)
        #expect(visionFiles.sorted() == files.map(\.name).sorted())
    }

    @Test
    func `Vision fallback uses bounded concurrency`() async throws {
        let files = (1 ... 12).map { makeSimilarityTestFile("file-\($0).ARW") }
        let tracker = SimilarityIndexingTestTracker()
        let model = SimilarityScoringModel()

        await model.indexFiles(
            files,
            preferredBackendOverride: .clip,
            embeddingComputer: { url, _, backend, _ in
                if backend == .clip {
                    return nil
                }
                await tracker.beginVisionWork()
                try? await Task.sleep(nanoseconds: 5_000_000)
                await tracker.endVisionWork(url: url)
                return SimilarityIndexResult(
                    embeddingData: Data("vision-\(url.lastPathComponent)".utf8),
                    clipLabel: nil,
                    clipConfidence: nil,
                )
            },
        )

        #expect(await tracker.maximumActiveVisionWork() <= 4)
        #expect(await tracker.fileNames(for: .visionFeaturePrint).count == files.count)
        #expect(model.didFallbackFromCLIP)
    }

    @Test
    func `cancelling indexing clears progress state`() async throws {
        let files = (1 ... 8).map { makeSimilarityTestFile("cancel-\($0).ARW") }
        let tracker = SimilarityIndexingTestTracker()
        let model = SimilarityScoringModel()

        let task = Task {
            await model.indexFiles(
                files,
                preferredBackendOverride: .visionFeaturePrint,
                embeddingComputer: { url, _, backend, _ in
                    await tracker.record(url: url, backend: backend)
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        return nil
                    }
                    return SimilarityIndexResult(
                        embeddingData: Data("vision-\(url.lastPathComponent)".utf8),
                        clipLabel: nil,
                        clipConfidence: nil,
                    )
                },
            )
        }

        for _ in 0 ..< 100 {
            if await tracker.totalCalls() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        model.cancelIndexing()
        await task.value

        #expect(model.isIndexing == false)
        #expect(model.indexingProgress == 0)
        #expect(model.indexingTotal == 0)
        #expect(model.indexingEstimatedSeconds == 0)
    }

    @Test
    func `burst grouping cache invalidates when embedding payload changes`() async throws {
        let files = [
            makeSimilarityTestFile("one.ARW", seconds: 0),
            makeSimilarityTestFile("two.ARW", seconds: 1),
            makeSimilarityTestFile("three.ARW", seconds: 2)
        ]
        let model = SimilarityScoringModel()
        model.embeddings = try [
            files[0].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([1.00, 0.00])),
            files[1].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.99, 0.01])),
            files[2].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.98, 0.02]))
        ]

        await model.groupBursts(files: files)
        #expect(model.burstGroups.count == 1)

        model.embeddings = try [
            files[0].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([1.00, 0.00])),
            files[1].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.99, 0.01])),
            files[2].id: #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.00, 1.00]))
        ]

        await model.groupBursts(files: files)

        #expect(model.burstGroups.count == 2)
        #expect(model.burstGroups.map(\.fileIDs) == [[files[0].id, files[1].id], [files[2].id]])
    }
}

private func makeSimilarityTestFile(_ name: String, seconds: TimeInterval = 0) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        name: name,
        size: 1,
        dateModified: Date(timeIntervalSince1970: seconds),
        exifData: nil,
        afFocusNormalized: nil,
    )
}

private actor SimilarityIndexingTestTracker {
    private var calls: [(url: URL, backend: SimilarityEmbeddingBackend)] = []
    private var activeVisionWork = 0
    private var maxActiveVisionWork = 0

    func record(url: URL, backend: SimilarityEmbeddingBackend) {
        calls.append((url, backend))
    }

    func fileNames(for backend: SimilarityEmbeddingBackend) -> [String] {
        calls
            .filter { $0.backend == backend }
            .map { $0.url.lastPathComponent }
    }

    func totalCalls() -> Int {
        calls.count
    }

    func beginVisionWork() {
        activeVisionWork += 1
        maxActiveVisionWork = max(maxActiveVisionWork, activeVisionWork)
    }

    func endVisionWork(url: URL) {
        calls.append((url, .visionFeaturePrint))
        activeVisionWork -= 1
    }

    func maximumActiveVisionWork() -> Int {
        maxActiveVisionWork
    }
}
