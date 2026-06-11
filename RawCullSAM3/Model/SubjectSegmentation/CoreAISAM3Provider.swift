import CoreAIImageSegmenter
import CoreGraphics
import Foundation

// The Core AI runtime package exposes ImageSegmenter as a value type with async
// inference APIs, but does not currently declare Sendable. RawCull keeps one
// instance actor-owned and only calls through this provider boundary.
extension ImageSegmenter: @retroactive @unchecked Sendable {}

actor CoreAISAM3Provider: SubjectSegmentationProvider {
    nonisolated let modelVersion = "coreai-sam3-local"

    private let resourcesURL: URL?
    private var segmenter: ImageSegmenter?

    init(resourcesURL: URL? = CoreAISAM3Provider.defaultResourcesURL()) {
        self.resourcesURL = resourcesURL
    }

    func segment(_ request: SubjectSegmentationRequest) async throws -> SubjectSegmentationResult {
        let totalStart = CFAbsoluteTimeGetCurrent()
        guard !Task.isCancelled else { throw SubjectSegmentationError.cancelled }
        let segmenter = try await loadSegmenter()

        let response = try await segmenter.segment(
            image: request.image,
            prompt: request.prompt.query,
        )
        guard !Task.isCancelled else { throw SubjectSegmentationError.cancelled }
        guard let segment = response.segments.first else {
            throw SubjectSegmentationError.noMask
        }

        let mask = try Self.makeMaskImage(from: segment)
        return SubjectSegmentationResult(
            fileID: request.fileID,
            requestID: request.requestID,
            prompt: request.prompt,
            mask: mask,
            confidence: segment.score,
            modelVersion: modelVersion,
            inputSize: request.inputSize,
            outputSize: CGSize(width: mask.width, height: mask.height),
            timing: SubjectSegmentationTiming(
                preprocessMilliseconds: nil,
                inferenceMilliseconds: nil,
                postprocessMilliseconds: nil,
                totalMilliseconds: (CFAbsoluteTimeGetCurrent() - totalStart) * 1000,
            ),
        )
    }

    private func loadSegmenter() async throws -> ImageSegmenter {
        if let segmenter {
            return segmenter
        }
        guard let resourcesURL else {
            throw SubjectSegmentationError.helperError(
                "Add SAM3.aimodel, SAM3.aimodelc, or a compiled SAM3 model folder to RawCullSAM3/Resources/Models",
            )
        }

        let loadedSegmenter = try await ImageSegmenter(resourcesAt: resourcesURL.path)
        segmenter = loadedSegmenter
        return loadedSegmenter
    }

    private nonisolated static func defaultResourcesURL(bundle: Bundle = .main) -> URL? {
        for subdirectory in ["Models", nil] {
            if let modelBundle = bundle.url(
                forResource: "SAM3",
                withExtension: nil,
                subdirectory: subdirectory,
            ) {
                return modelBundle
            }
            if let compiledModel = bundle.url(
                forResource: "SAM3",
                withExtension: "aimodelc",
                subdirectory: subdirectory,
            ) {
                return compiledModel
            }
            if let sourceModel = bundle.url(
                forResource: "SAM3",
                withExtension: "aimodel",
                subdirectory: subdirectory,
            ) {
                return sourceModel
            }
        }
        return nil
    }

    private nonisolated static func makeMaskImage(from segment: Segment) throws -> CGImage {
        let width = segment.maskWidth
        let height = segment.maskHeight
        guard width > 0,
              height > 0,
              segment.mask.count == width * height
        else {
            throw SubjectSegmentationError.decodeFailure
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            for index in segment.mask.indices where segment.mask[index] {
                let offset = index * 4
                baseAddress[offset + 0] = 255
                baseAddress[offset + 1] = 255
                baseAddress[offset + 2] = 255
                baseAddress[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent,
              )
        else {
            throw SubjectSegmentationError.decodeFailure
        }

        return image
    }
}
