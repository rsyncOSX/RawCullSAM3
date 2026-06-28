import CoreGraphics
import Foundation
import ImageIO
import RawCullCore
import UniformTypeIdentifiers

actor SubjectSegmentationActor {
    private let provider: any SubjectSegmentationProvider
    private let cache: SubjectMaskCache
    private let diskCache: SAM3MaskDiskCache
    private let maxSide: Int
    private var activeRequestID: UUID?

    init(maxSide: Int = 4320) {
        provider = CoreAISAM3Provider()
        cache = SubjectMaskCache()
        diskCache = SharedMemoryCache.shared.sam3MaskDiskCache
        self.maxSide = maxSide
    }

    init(
        provider: any SubjectSegmentationProvider,
        cache: SubjectMaskCache,
        diskCache: SAM3MaskDiskCache = SAM3MaskDiskCache(),
        maxSide: Int = 4320,
    ) {
        self.provider = provider
        self.cache = cache
        self.diskCache = diskCache
        self.maxSide = maxSide
    }

    func partitionByValidDiskCache(
        files: [FileItem],
        prompt: SubjectSegmentationPrompt,
    ) async throws -> (cached: [FileItem], missing: [FileItem]) {
        var cached: [FileItem] = []
        var missing: [FileItem] = []

        for file in files {
            try Task.checkCancellation()
            let isCached = await diskCache.containsValidMask(
                for: file.url,
                prompt: prompt,
                modelVersion: provider.modelVersion,
                inputMaxSide: maxSide,
            )
            if isCached {
                cached.append(file)
            } else {
                missing.append(file)
            }
        }

        return (cached, missing)
    }

    func segment(
        image: CGImage,
        fileID: UUID,
        fileURL: URL,
        prompt: SubjectSegmentationPrompt,
    ) async throws -> SubjectSegmentationResult {
        let key = await cacheKey(fileID: fileID, fileURL: fileURL, prompt: prompt)
        if let cached = await cache.result(for: key) {
            return cached
        }
        if let diskResult = await diskCache.load(
            for: fileURL,
            fileID: fileID,
            prompt: prompt,
            modelVersion: provider.modelVersion,
            inputMaxSide: maxSide,
        ) {
            await cache.store(diskResult, for: key)
            return diskResult
        }

        try Task.checkCancellation()

        let requestID = UUID()
        activeRequestID = requestID

        guard let boundedImage = Self.boundedImage(image, maxSide: maxSide),
              let imageData = Self.jpegData(from: boundedImage)
        else {
            throw SubjectSegmentationError.decodeFailure
        }

        let request = SubjectSegmentationRequest(
            requestID: requestID,
            fileID: fileID,
            prompt: prompt,
            image: boundedImage,
            imageData: imageData,
            imageFormat: "jpeg",
            inputSize: CGSize(width: boundedImage.width, height: boundedImage.height),
            outputSize: CGSize(width: image.width, height: image.height),
            maxSide: maxSide,
        )

        let result = try await provider.segment(request)
        guard activeRequestID == requestID else {
            throw SubjectSegmentationError.staleResponse
        }
        guard !Task.isCancelled else {
            throw SubjectSegmentationError.cancelled
        }

        let displayMask = Self.resizedImage(
            result.mask,
            width: image.width,
            height: image.height,
        ) ?? result.mask
        let displayResult = SubjectSegmentationResult(
            fileID: result.fileID,
            requestID: result.requestID,
            prompt: result.prompt,
            mask: displayMask,
            confidence: result.confidence,
            modelVersion: result.modelVersion,
            inputSize: result.inputSize,
            outputSize: CGSize(width: displayMask.width, height: displayMask.height),
            timing: result.timing,
            diagnostics: SubjectSegmentationDiagnostics(
                modelVersion: result.diagnostics.modelVersion,
                prompt: result.diagnostics.prompt,
                confidence: result.diagnostics.confidence,
                timing: result.diagnostics.timing,
                inputSize: result.diagnostics.inputSize,
                outputSize: CGSize(width: displayMask.width, height: displayMask.height),
                resourceName: result.diagnostics.resourceName,
                assetName: result.diagnostics.assetName,
            ),
        )
        await cache.store(displayResult, for: key)
        await diskCache.save(displayResult, for: fileURL, inputMaxSide: maxSide)
        return displayResult
    }

    func prefetch(
        files: [FileItem],
        prompt: SubjectSegmentationPrompt,
        imageLoader: @escaping @Sendable (FileItem) async -> CGImage?,
        progress: (@Sendable (SubjectMaskPrefetchProgress) async -> Void)? = nil,
    ) async throws {
        let total = files.count
        var completed = 0
        var cached = 0
        var generated = 0
        var failed = 0

        await progress?(SubjectMaskPrefetchProgress(
            completed: completed,
            total: total,
            cached: cached,
            generated: generated,
            failed: failed,
            currentFileID: files.first?.id,
        ))

        for file in files {
            try Task.checkCancellation()

            let key = await cacheKey(fileID: file.id, fileURL: file.url, prompt: prompt)
            if await cache.result(for: key) != nil {
                cached += 1
                completed += 1
                await progress?(SubjectMaskPrefetchProgress(
                    completed: completed,
                    total: total,
                    cached: cached,
                    generated: generated,
                    failed: failed,
                    currentFileID: file.id,
                ))
                continue
            }
            if let diskResult = await diskCache.load(
                for: file.url,
                fileID: file.id,
                prompt: prompt,
                modelVersion: provider.modelVersion,
                inputMaxSide: maxSide,
            ) {
                await cache.store(diskResult, for: key)
                cached += 1
                completed += 1
                await progress?(SubjectMaskPrefetchProgress(
                    completed: completed,
                    total: total,
                    cached: cached,
                    generated: generated,
                    failed: failed,
                    currentFileID: file.id,
                ))
                continue
            }

            guard let image = await imageLoader(file) else {
                try Task.checkCancellation()
                failed += 1
                completed += 1
                await progress?(SubjectMaskPrefetchProgress(
                    completed: completed,
                    total: total,
                    cached: cached,
                    generated: generated,
                    failed: failed,
                    currentFileID: file.id,
                ))
                continue
            }

            try Task.checkCancellation()
            do {
                _ = try await segment(image: image, fileID: file.id, fileURL: file.url, prompt: prompt)
                generated += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SubjectSegmentationError where error == .cancelled || error == .staleResponse {
                throw CancellationError()
            } catch {
                failed += 1
            }
            completed += 1
            await progress?(SubjectMaskPrefetchProgress(
                completed: completed,
                total: total,
                cached: cached,
                generated: generated,
                failed: failed,
                currentFileID: file.id,
            ))
        }
    }

    private func cacheKey(
        fileID: UUID,
        fileURL: URL,
        prompt: SubjectSegmentationPrompt,
    ) async -> SubjectMaskCacheKey {
        let path = fileURL.path
        let modelVersion = provider.modelVersion
        let maxSide = self.maxSide
        let (fileSize, modificationDate): (Int64?, Date?) = await Task.detached(priority: .utility) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (
                (attributes?[.size] as? NSNumber).map { $0.int64Value },
                attributes?[.modificationDate] as? Date,
            )
        }.value
        return SubjectMaskCacheKey(
            fileID: fileID,
            prompt: prompt,
            modelVersion: modelVersion,
            inputMaxSide: maxSide,
            fileSize: fileSize,
            modificationDate: modificationDate,
        )
    }

    private nonisolated static func boundedImage(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > maxSide else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longestSide)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        return resizedImage(image, width: width, height: height, interpolationQuality: .high)
    }

    private nonisolated static func resizedImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        interpolationQuality: CGInterpolationQuality = .high,
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard image.width != width || image.height != height else { return image }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.interpolationQuality = interpolationQuality
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private nonisolated static func jpegData(from image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
