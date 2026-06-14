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
        #expect(SimilarityScoringModel.preferredEmbeddingBackend(clipModelURL: URL(fileURLWithPath: "/tmp/CLIP")) == .clip)
        #expect(SimilarityScoringModel.preferredEmbeddingBackend(clipModelURL: nil) == .visionFeaturePrint)
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
        model.embeddings = [
            anchor.id: try #require(SimilarityEmbeddingEnvelope.encodeCLIP([1, 0, 0])),
            near.id: try #require(SimilarityEmbeddingEnvelope.encodeCLIP([0.95, 0.05, 0])),
            far.id: try #require(SimilarityEmbeddingEnvelope.encodeCLIP([0, 1, 0])),
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
}

private func makeSimilarityTestFile(_ name: String) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        name: name,
        size: 1,
        dateModified: Date(timeIntervalSince1970: 0),
        exifData: nil,
        afFocusNormalized: nil,
    )
}
