import Foundation
import RawCullCore

enum SAM3SubjectMaskCacheReader {
    static let prompt: SubjectSegmentationPrompt = .subject
    static let modelVersion = "coreai-sam3-local"
    static let inputMaxSide = 4320

    static func loadCachedMask(
        for file: FileItem,
        diskCache: SAM3MaskDiskCache = SharedMemoryCache.shared.sam3MaskDiskCache,
    ) async -> SubjectSegmentationResult? {
        await diskCache.load(
            for: file.url,
            fileID: file.id,
            prompt: prompt,
            modelVersion: modelVersion,
            inputMaxSide: inputMaxSide,
        )
    }
}
