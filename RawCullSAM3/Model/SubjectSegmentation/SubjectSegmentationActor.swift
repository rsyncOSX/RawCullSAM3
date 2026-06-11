import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor SubjectSegmentationActor {
    private let provider: any SubjectSegmentationProvider
    private let cache: SubjectMaskCache
    private let maxSide: Int
    private var activeRequestID: UUID?

    init(maxSide: Int = 1024) {
        provider = CoreAISAM3Provider()
        cache = SubjectMaskCache()
        self.maxSide = maxSide
    }

    init(
        provider: any SubjectSegmentationProvider,
        cache: SubjectMaskCache,
        maxSide: Int = 1024,
    ) {
        self.provider = provider
        self.cache = cache
        self.maxSide = maxSide
    }

    func cancelActiveRequest() {
        activeRequestID = nil
    }

    func segment(
        image: CGImage,
        fileID: UUID,
        fileURL: URL,
        prompt: SubjectSegmentationPrompt,
    ) async throws -> SubjectSegmentationResult {
        let key = cacheKey(fileID: fileID, fileURL: fileURL, prompt: prompt)
        if let cached = await cache.result(for: key) {
            return cached
        }

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
        )
        await cache.store(displayResult, for: key)
        return displayResult
    }

    private func cacheKey(
        fileID: UUID,
        fileURL: URL,
        prompt: SubjectSegmentationPrompt,
    ) -> SubjectMaskCacheKey {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SubjectMaskCacheKey(
            fileID: fileID,
            prompt: prompt,
            modelVersion: provider.modelVersion,
            inputMaxSide: maxSide,
            fileSize: values?.fileSize.map(Int64.init),
            modificationDate: values?.contentModificationDate,
        )
    }

    private nonisolated static func boundedImage(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > maxSide else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longestSide)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        return resizedImage(image, width: width, height: height)
    }

    private nonisolated static func resizedImage(
        _ image: CGImage,
        width: Int,
        height: Int,
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
        context.interpolationQuality = .medium
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
