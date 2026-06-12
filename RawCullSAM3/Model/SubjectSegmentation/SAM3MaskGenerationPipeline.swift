import CoreGraphics
import Foundation

struct SAM3MaskGenerationPipeline {
    let actor: SubjectSegmentationActor
    let prompt: SubjectSegmentationPrompt
    let imageLoader: @Sendable (FileItem) async -> CGImage?

    init(
        actor: SubjectSegmentationActor,
        prompt: SubjectSegmentationPrompt = SAM3SubjectMaskCacheReader.prompt,
        imageLoader: @escaping @Sendable (FileItem) async -> CGImage?,
    ) {
        self.actor = actor
        self.prompt = prompt
        self.imageLoader = imageLoader
    }

    func generate(
        files: [FileItem],
        progress: (@Sendable (SAM3MaskBuildEvent) async -> Void)? = nil,
    ) async throws -> SAM3MaskBuildSummary {
        let fileNamesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.name) })
        await progress?(.started(total: files.count))

        let recorder = SAM3MaskGenerationProgressRecorder(initial: SubjectMaskPrefetchProgress(
            completed: 0,
            total: files.count,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileID: files.first?.id,
        ))

        try await actor.prefetch(
            files: files,
            prompt: prompt,
            imageLoader: imageLoader,
            progress: { update in
                await recorder.record(update)
                await progress?(.progress(
                    update,
                    currentFileName: update.currentFileID.flatMap { fileNamesByID[$0] },
                ))
            },
        )

        let latest = await recorder.latest()
        let summary = SAM3MaskBuildSummary(
            total: latest.total,
            cached: latest.cached,
            generated: latest.generated,
            failed: latest.failed,
        )
        await progress?(.completed(summary))
        return summary
    }
}

private actor SAM3MaskGenerationProgressRecorder {
    private var value: SubjectMaskPrefetchProgress

    init(initial: SubjectMaskPrefetchProgress) {
        value = initial
    }

    func record(_ progress: SubjectMaskPrefetchProgress) {
        value = progress
    }

    func latest() -> SubjectMaskPrefetchProgress {
        value
    }
}
