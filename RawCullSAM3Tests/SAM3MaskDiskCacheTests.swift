import AppKit
import Foundation
import RawCullCore
@testable import RawCullSAM3
import Testing

private func makeSAM3CacheTestRoot(_ name: String = #function) throws -> URL {
    let safeName = name
        .replacingOccurrences(of: "`", with: "")
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "()", with: "")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RawCullVerifyTests", isDirectory: true)
        .appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private nonisolated func makeSAM3CacheTestCGImage(
    width: Int = 32,
    height: Int = 24,
    color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func makeSAM3CacheSource(in root: URL, name: String = "source.ARW", data: Data = Data([1, 2, 3])) throws -> URL {
    let url = root.appendingPathComponent(name)
    try data.write(to: url)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

private func makeSAM3Result(
    fileID: UUID = UUID(),
    prompt: SubjectSegmentationPrompt = .bird,
    modelVersion: String = "test-sam3",
    confidence: Float = 0.82,
    width: Int = 32,
    height: Int = 24,
) throws -> SubjectSegmentationResult {
    let mask = try makeSAM3CacheTestCGImage(width: width, height: height)
    let timing = SubjectSegmentationTiming(
        preprocessMilliseconds: nil,
        inferenceMilliseconds: nil,
        postprocessMilliseconds: nil,
        totalMilliseconds: 12,
    )
    let size = CGSize(width: width, height: height)
    let diagnostics = SubjectSegmentationDiagnostics(
        modelVersion: modelVersion,
        prompt: prompt,
        confidence: confidence,
        timing: timing,
        inputSize: size,
        outputSize: size,
        resourceName: "test",
        assetName: "test",
    )
    return SubjectSegmentationResult(
        fileID: fileID,
        requestID: UUID(),
        prompt: prompt,
        mask: mask,
        confidence: confidence,
        modelVersion: modelVersion,
        inputSize: size,
        outputSize: size,
        timing: timing,
        diagnostics: diagnostics,
    )
}

struct SAM3MaskDiskCacheTests {
    @Test
    func `save and load mask round trip preserves result metadata`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let cache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let fileID = UUID()
        let result = try makeSAM3Result(fileID: fileID, prompt: .bird, confidence: 0.91, width: 40, height: 30)

        await cache.save(result, for: source, inputMaxSide: 4320)
        let loaded = await cache.load(
            for: source,
            fileID: fileID,
            prompt: .bird,
            modelVersion: "test-sam3",
            inputMaxSide: 4320,
        )

        #expect(loaded?.fileID == fileID)
        #expect(loaded?.prompt == .bird)
        #expect(loaded?.modelVersion == "test-sam3")
        #expect(loaded?.confidence == 0.91)
        #expect(loaded?.mask.width == 40)
        #expect(loaded?.mask.height == 30)
        #expect(await cache.getDiskCacheSize() > 0)
    }

    @Test
    func `stale source metadata causes cache miss`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let cache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let result = try makeSAM3Result()

        await cache.save(result, for: source, inputMaxSide: 4320)
        try Data([1, 2, 3, 4, 5]).write(to: source)

        let loaded = await cache.load(
            for: source,
            fileID: result.fileID,
            prompt: result.prompt,
            modelVersion: result.modelVersion,
            inputMaxSide: 4320,
        )

        #expect(loaded == nil)
    }

    @Test
    func `prompt model and input size create separate entries`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let cache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))

        try await cache.save(makeSAM3Result(prompt: .bird, modelVersion: "a"), for: source, inputMaxSide: 1024)
        try await cache.save(makeSAM3Result(prompt: .animal, modelVersion: "a"), for: source, inputMaxSide: 1024)
        try await cache.save(makeSAM3Result(prompt: .bird, modelVersion: "b"), for: source, inputMaxSide: 1024)
        try await cache.save(makeSAM3Result(prompt: .bird, modelVersion: "a"), for: source, inputMaxSide: 2048)

        let entries = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Masks", isDirectory: true),
            includingPropertiesForKeys: nil,
        )
        #expect(entries.count == 8)
    }

    @Test
    func `prune and removeAll clear mask and metadata files`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let directory = root.appendingPathComponent("Masks", isDirectory: true)
        let cache = SAM3MaskDiskCache(cacheDirectory: directory)
        let result = try makeSAM3Result()

        await cache.save(result, for: source, inputMaxSide: 4320)
        for fileURL in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let oldDate = Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileURL.path)
        }
        await cache.pruneCache(maxAgeInDays: 1)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)

        await cache.save(result, for: source, inputMaxSide: 4320)
        await cache.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
}

private actor FakeSubjectSegmentationProvider: SubjectSegmentationProvider {
    nonisolated let modelVersion = "fake-sam3"
    private var segmentCallCount = 0

    func segment(_ request: SubjectSegmentationRequest) async throws -> SubjectSegmentationResult {
        segmentCallCount += 1
        let mask = try makeSAM3CacheTestCGImage(
            width: Int(request.inputSize.width),
            height: Int(request.inputSize.height),
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        )
        let timing = SubjectSegmentationTiming(
            preprocessMilliseconds: nil,
            inferenceMilliseconds: nil,
            postprocessMilliseconds: nil,
            totalMilliseconds: 1,
        )
        let diagnostics = SubjectSegmentationDiagnostics(
            modelVersion: modelVersion,
            prompt: request.prompt,
            confidence: 0.77,
            timing: timing,
            inputSize: request.inputSize,
            outputSize: request.inputSize,
            resourceName: "fake",
            assetName: "fake",
        )
        return SubjectSegmentationResult(
            fileID: request.fileID,
            requestID: request.requestID,
            prompt: request.prompt,
            mask: mask,
            confidence: 0.77,
            modelVersion: modelVersion,
            inputSize: request.inputSize,
            outputSize: request.inputSize,
            timing: timing,
            diagnostics: diagnostics,
        )
    }

    func callCount() -> Int {
        segmentCallCount
    }
}

private actor SAM3PrefetchProgressRecorder {
    private var latestProgress: SubjectMaskPrefetchProgress?

    func record(_ progress: SubjectMaskPrefetchProgress) {
        latestProgress = progress
    }

    func latest() -> SubjectMaskPrefetchProgress? {
        latestProgress
    }
}

private func makeSAM3TestFileItem(url: URL) -> FileItem {
    FileItem(
        url: url,
        name: url.lastPathComponent,
        size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
        dateModified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
        exifData: nil,
        afFocusNormalized: nil,
    )
}

struct SubjectSegmentationActorCacheTests {
    @Test
    func `first segment writes disk cache and second actor reads without provider`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let firstProvider = FakeSubjectSegmentationProvider()
        let image = try makeSAM3CacheTestCGImage(width: 44, height: 22)
        let fileID = UUID()
        let firstActor = SubjectSegmentationActor(
            provider: firstProvider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )

        _ = try await firstActor.segment(image: image, fileID: fileID, fileURL: source, prompt: .bird)

        let secondProvider = FakeSubjectSegmentationProvider()
        let secondActor = SubjectSegmentationActor(
            provider: secondProvider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        let loaded = try await secondActor.segment(image: image, fileID: fileID, fileURL: source, prompt: .bird)

        #expect(await firstProvider.callCount() == 1)
        #expect(await secondProvider.callCount() == 0)
        #expect(loaded.mask.width == 44)
        #expect(loaded.mask.height == 22)
    }

    @Test
    func `stale disk cache forces provider call`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let image = try makeSAM3CacheTestCGImage()
        let firstActor = SubjectSegmentationActor(
            provider: FakeSubjectSegmentationProvider(),
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        _ = try await firstActor.segment(image: image, fileID: UUID(), fileURL: source, prompt: .bird)
        try Data([9, 8, 7, 6]).write(to: source)

        let provider = FakeSubjectSegmentationProvider()
        let secondActor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        _ = try await secondActor.segment(image: image, fileID: UUID(), fileURL: source, prompt: .bird)

        #expect(await provider.callCount() == 1)
    }

    @Test
    func `prefetch skips disk cached entries and reports progress`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachedSource = try makeSAM3CacheSource(in: root, name: "cached.ARW")
        let uncachedSource = try makeSAM3CacheSource(in: root, name: "uncached.ARW")
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let image = try makeSAM3CacheTestCGImage(width: 20, height: 10)
        let cachedActor = SubjectSegmentationActor(
            provider: FakeSubjectSegmentationProvider(),
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        _ = try await cachedActor.segment(image: image, fileID: UUID(), fileURL: cachedSource, prompt: .bird)

        let provider = FakeSubjectSegmentationProvider()
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        let recorder = SAM3PrefetchProgressRecorder()
        try await actor.prefetch(
            files: [makeSAM3TestFileItem(url: cachedSource), makeSAM3TestFileItem(url: uncachedSource)],
            prompt: .bird,
            imageLoader: { _ in image },
            progress: { progress in await recorder.record(progress) },
        )
        let latestProgress = await recorder.latest()

        #expect(await provider.callCount() == 1)
        #expect(latestProgress?.completed == 2)
        #expect(latestProgress?.cached == 1)
        #expect(latestProgress?.generated == 1)
    }

    @Test
    func `generation pipeline emits started progress and completed events`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let provider = FakeSubjectSegmentationProvider()
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let image = try makeSAM3CacheTestCGImage(width: 24, height: 12)
        let file = makeSAM3TestFileItem(url: source)
        let recorder = SAM3MaskBuildEventRecorder()
        let pipeline = SAM3MaskGenerationPipeline(
            actor: actor,
            imageLoader: { _ in image },
        )

        let summary = try await pipeline.generate(files: [file]) { event in
            await recorder.record(event)
        }
        let events = await recorder.events()

        #expect(summary.total == 1)
        #expect(summary.generated == 1)
        #expect(events.first?.kind == .started)
        #expect(events.contains { $0.kind == .progress && $0.currentFileName == "source.ARW" })
        #expect(events.last?.kind == .completed)
    }

    @Test
    func `generation pipeline validates disk cache and generates only missing masks`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachedSource = try makeSAM3CacheSource(in: root, name: "cached.ARW")
        let missingSource = try makeSAM3CacheSource(in: root, name: "missing.ARW")
        let cachedFile = makeSAM3TestFileItem(url: cachedSource)
        let missingFile = makeSAM3TestFileItem(url: missingSource)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let provider = FakeSubjectSegmentationProvider()
        let cachedResult = try makeSAM3Result(
            fileID: cachedFile.id,
            prompt: .subject,
            modelVersion: provider.modelVersion,
            width: 24,
            height: 12,
        )
        await diskCache.save(cachedResult, for: cachedSource, inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide)
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let image = try makeSAM3CacheTestCGImage(width: 24, height: 12)
        let recorder = SAM3MaskBuildEventRecorder()
        let pipeline = SAM3MaskGenerationPipeline(
            actor: actor,
            imageLoader: { _ in image },
        )

        let summary = try await pipeline.generate(files: [cachedFile, missingFile]) { event in
            await recorder.record(event)
        }
        let events = await recorder.events()

        #expect(await provider.callCount() == 1)
        #expect(summary.total == 2)
        #expect(summary.cached == 1)
        #expect(summary.generated == 1)
        #expect(events.first == .started(total: 2))
        #expect(events.contains { event in
            event.kind == .progress &&
                event.completed == 1 &&
                event.total == 2 &&
                event.cached == 1 &&
                event.generated == 0
        })
        #expect(events.last == .completed(summary))
    }

    @Test
    func `generation pipeline treats stale disk cache as missing`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let provider = FakeSubjectSegmentationProvider()
        let cachedResult = try makeSAM3Result(
            fileID: file.id,
            prompt: .subject,
            modelVersion: provider.modelVersion,
        )
        await diskCache.save(cachedResult, for: source, inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide)
        try Data([9, 8, 7, 6]).write(to: source)
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let image = try makeSAM3CacheTestCGImage()
        let pipeline = SAM3MaskGenerationPipeline(
            actor: actor,
            imageLoader: { _ in image },
        )

        let summary = try await pipeline.generate(files: [file])

        #expect(await provider.callCount() == 1)
        #expect(summary.cached == 0)
        #expect(summary.generated == 1)
    }

    @Test
    func `generation pipeline treats corrupt mask cache as missing and rewrites it`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let cacheDirectory = root.appendingPathComponent("Masks", isDirectory: true)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: cacheDirectory)
        let provider = FakeSubjectSegmentationProvider()
        let cachedResult = try makeSAM3Result(
            fileID: file.id,
            prompt: .subject,
            modelVersion: provider.modelVersion,
        )
        await diskCache.save(cachedResult, for: source, inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide)
        let cachedFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
        )
        let maskURL = try #require(cachedFiles.first { $0.pathExtension == "png" })
        try Data([0, 1, 2, 3]).write(to: maskURL, options: .atomic)
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let image = try makeSAM3CacheTestCGImage(width: 28, height: 14)
        let pipeline = SAM3MaskGenerationPipeline(
            actor: actor,
            imageLoader: { _ in image },
        )

        let summary = try await pipeline.generate(files: [file])
        let loaded = await diskCache.load(
            for: source,
            fileID: file.id,
            prompt: .subject,
            modelVersion: provider.modelVersion,
            inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )

        #expect(await provider.callCount() == 1)
        #expect(summary.cached == 0)
        #expect(summary.generated == 1)
        #expect(loaded?.mask.width == 28)
        #expect(loaded?.mask.height == 14)
    }

    @Test
    func `prefetch stops on cancellation`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let actor = SubjectSegmentationActor(
            provider: FakeSubjectSegmentationProvider(),
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: 4320,
        )
        let files = [
            makeSAM3TestFileItem(url: source),
            makeSAM3TestFileItem(url: source),
            makeSAM3TestFileItem(url: source)
        ]
        let image = try makeSAM3CacheTestCGImage()

        let task = Task {
            try await actor.prefetch(
                files: files,
                prompt: .bird,
                imageLoader: { _ in
                    try? await Task.sleep(for: .milliseconds(100))
                    return image
                },
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            try await task.value
            Issue.record("Prefetch completed despite cancellation")
        } catch is CancellationError {}
    }
}

private actor SAM3MaskBuildEventRecorder {
    private var recordedEvents: [SAM3MaskBuildEvent] = []

    func record(_ event: SAM3MaskBuildEvent) {
        recordedEvents.append(event)
    }

    func events() -> [SAM3MaskBuildEvent] {
        recordedEvents
    }
}

struct SAM3SubjectMaskCacheReaderTests {
    @Test
    func `loads cached subject mask with default SAM3 cache key`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let result = try makeSAM3Result(
            fileID: file.id,
            prompt: .subject,
            modelVersion: SAM3SubjectMaskCacheReader.modelVersion,
            width: 36,
            height: 18,
        )

        await diskCache.save(result, for: source, inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide)
        let loaded = await SAM3SubjectMaskCacheReader.loadCachedMask(for: file, diskCache: diskCache)

        #expect(loaded?.fileID == file.id)
        #expect(loaded?.prompt == .subject)
        #expect(loaded?.modelVersion == SAM3SubjectMaskCacheReader.modelVersion)
        #expect(loaded?.mask.width == 36)
        #expect(loaded?.mask.height == 18)
    }

    @Test
    func `missing subject mask cache returns nil`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))

        let loaded = await SAM3SubjectMaskCacheReader.loadCachedMask(for: file, diskCache: diskCache)

        #expect(loaded == nil)
    }

    @Test
    func `wrong prompt cache does not satisfy subject mask reader`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let result = try makeSAM3Result(
            fileID: file.id,
            prompt: .bird,
            modelVersion: SAM3SubjectMaskCacheReader.modelVersion,
        )

        await diskCache.save(result, for: source, inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide)
        let loaded = await SAM3SubjectMaskCacheReader.loadCachedMask(for: file, diskCache: diskCache)

        #expect(loaded == nil)
    }

    @Test
    func `build event JSON round trip preserves progress payload`() throws {
        let progress = SubjectMaskPrefetchProgress(
            completed: 2,
            total: 5,
            cached: 1,
            generated: 1,
            failed: 0,
            currentFileID: UUID(),
        )
        let event = SAM3MaskBuildEvent.progress(progress, currentFileName: "two.ARW")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SAM3MaskBuildEvent.self, from: data)

        #expect(decoded == event)
        #expect(decoded.prefetchProgress?.remaining == 3)
    }
}

@MainActor
struct SAM3MaskCreationViewModelTests {
    @Test
    func `SAM3 prefetch progress remaining count is clamped at zero`() {
        let inProgress = SubjectMaskPrefetchProgress(
            completed: 3,
            total: 5,
            cached: 0,
            generated: 3,
            failed: 0,
            currentFileID: nil,
        )
        let overComplete = SubjectMaskPrefetchProgress(
            completed: 6,
            total: 5,
            cached: 0,
            generated: 5,
            failed: 1,
            currentFileID: nil,
        )

        #expect(inProgress.remaining == 2)
        #expect(overComplete.remaining == 0)
    }

    @Test
    func `candidate files use current rating filter`() throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keepSource = try makeSAM3CacheSource(in: root, name: "keep.ARW")
        let rejectSource = try makeSAM3CacheSource(in: root, name: "reject.ARW")
        let keep = makeSAM3TestFileItem(url: keepSource)
        let reject = makeSAM3TestFileItem(url: rejectSource)
        let viewModel = RawCullViewModel()

        viewModel.selectedSource = ARWSourceCatalog(name: "SAM3 Test", url: root)
        viewModel.cullingModel = CullingModel(saveDelayNanoseconds: 0, saveHandler: { _ in })
        viewModel.filteredFiles = [reject, keep]
        viewModel.files = [reject, keep]
        viewModel.updateRating(for: keep, rating: 3)
        viewModel.updateRating(for: reject, rating: -1)
        viewModel.ratingFilter = .stars(3)

        #expect(viewModel.sam3MaskCreationCandidateFiles.map(\.id) == [keep.id])
    }

    @Test
    func `SAM3 mask creation updates progress and clears running state on completion`() async throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let diskCache = SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true))
        let provider = FakeSubjectSegmentationProvider()
        let actor = SubjectSegmentationActor(
            provider: provider,
            cache: SubjectMaskCache(),
            diskCache: diskCache,
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let image = try makeSAM3CacheTestCGImage(width: 18, height: 12)
        let viewModel = RawCullViewModel()
        viewModel.filteredFiles = [file]

        viewModel.startSAM3MaskCreationForFilteredCatalog(
            actor: actor,
            imageLoader: { _ in image },
        )

        try await waitUntil(timeoutSeconds: 2) {
            !viewModel.isCreatingSAM3Masks
        }

        #expect(viewModel.sam3MaskCreationProgress?.completed == 1)
        #expect(viewModel.sam3MaskCreationProgress?.generated == 1)
        #expect(await provider.callCount() == 1)
        let cached = await diskCache.load(
            for: source,
            fileID: file.id,
            prompt: .subject,
            modelVersion: provider.modelVersion,
            inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        #expect(cached != nil)
    }

    @Test
    func `cancelling SAM3 mask creation clears running state`() throws {
        let root = try makeSAM3CacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSAM3CacheSource(in: root)
        let file = makeSAM3TestFileItem(url: source)
        let actor = SubjectSegmentationActor(
            provider: FakeSubjectSegmentationProvider(),
            cache: SubjectMaskCache(),
            diskCache: SAM3MaskDiskCache(cacheDirectory: root.appendingPathComponent("Masks", isDirectory: true)),
            maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )
        let viewModel = RawCullViewModel()
        viewModel.filteredFiles = [file]

        viewModel.startSAM3MaskCreationForFilteredCatalog(
            actor: actor,
            imageLoader: { _ in
                try? await Task.sleep(for: .seconds(1))
                return nil
            },
        )
        #expect(viewModel.isCreatingSAM3Masks)

        viewModel.cancelSAM3MaskCreation(clearProgress: true)

        #expect(!viewModel.isCreatingSAM3Masks)
        #expect(viewModel.sam3MaskCreationProgress == nil)
    }

    private func waitUntil(
        timeoutSeconds: Double,
        condition: @escaping @MainActor () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
