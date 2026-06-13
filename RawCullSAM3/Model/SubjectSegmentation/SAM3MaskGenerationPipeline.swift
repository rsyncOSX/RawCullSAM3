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

        let partition = try await actor.partitionByValidDiskCache(files: files, prompt: prompt)
        let initialCached = partition.cached.count

        let recorder = SAM3MaskGenerationProgressRecorder(initial: SubjectMaskPrefetchProgress(
            completed: initialCached,
            total: files.count,
            cached: initialCached,
            generated: 0,
            failed: 0,
            currentFileID: partition.missing.first?.id,
        ))
        if initialCached > 0 {
            await progress?(.progress(
                recorder.latest(),
                currentFileName: partition.missing.first?.name,
            ))
        }

        guard !partition.missing.isEmpty else {
            let summary = SAM3MaskBuildSummary(
                total: files.count,
                cached: initialCached,
                generated: 0,
                failed: 0,
            )
            await progress?(.completed(summary))
            return summary
        }

        try await actor.prefetch(
            files: partition.missing,
            prompt: prompt,
            imageLoader: imageLoader,
            progress: { update in
                let translated = SubjectMaskPrefetchProgress(
                    completed: initialCached + update.completed,
                    total: files.count,
                    cached: initialCached + update.cached,
                    generated: update.generated,
                    failed: update.failed,
                    currentFileID: update.currentFileID,
                )
                await recorder.record(translated)
                await progress?(.progress(
                    translated,
                    currentFileName: translated.currentFileID.flatMap { fileNamesByID[$0] },
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
