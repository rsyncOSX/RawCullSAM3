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

        let response: SegmentationResponse
        do {
            response = try await segmenter.segment(
                image: request.image,
                prompt: request.prompt.query,
            )
        } catch let error as SubjectSegmentationError {
            throw error
        } catch {
            throw SubjectSegmentationError.helperError(
                "Core AI SAM3 inference failed: \(Self.message(for: error))",
            )
        }
        guard !Task.isCancelled else { throw SubjectSegmentationError.cancelled }
        guard let segment = response.segments.first else {
            throw SubjectSegmentationError.noMask
        }

        let mask = try Self.makeMaskImage(from: segment)
        let timing = SubjectSegmentationTiming(
            preprocessMilliseconds: nil,
            inferenceMilliseconds: nil,
            postprocessMilliseconds: nil,
            totalMilliseconds: (CFAbsoluteTimeGetCurrent() - totalStart) * 1000,
        )
        let outputSize = CGSize(width: mask.width, height: mask.height)
        let diagnostics = SubjectSegmentationDiagnostics(
            modelVersion: modelVersion,
            prompt: request.prompt,
            confidence: segment.score,
            timing: timing,
            inputSize: request.inputSize,
            outputSize: outputSize,
            resourceName: Self.resourceName(in: resourcesURL),
            assetName: Self.assetName(in: resourcesURL),
        )
        return SubjectSegmentationResult(
            fileID: request.fileID,
            requestID: request.requestID,
            prompt: request.prompt,
            mask: mask,
            confidence: segment.score,
            modelVersion: modelVersion,
            inputSize: request.inputSize,
            outputSize: outputSize,
            timing: timing,
            diagnostics: diagnostics,
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

        let loadedSegmenter: ImageSegmenter
        do {
            loadedSegmenter = try await ImageSegmenter(resourcesAt: resourcesURL.path)
        } catch let error as SubjectSegmentationError {
            throw error
        } catch {
            throw SubjectSegmentationError.helperError(
                "Core AI SAM3 load failed: \(Self.loadFailureMessage(for: error, resourcesURL: resourcesURL))",
            )
        }
        segmenter = loadedSegmenter
        return loadedSegmenter
    }

    private nonisolated static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty,
           description != "The operation couldn’t be completed. (Swift.Error error 1.)" {
            return description
        }
        return String(reflecting: error)
    }

    private nonisolated static func loadFailureMessage(for error: Error, resourcesURL: URL) -> String {
        var message = message(for: error)
        guard let assetName = assetName(in: resourcesURL),
              assetName.hasSuffix(".aimodelc"),
              assetName.contains(".h16c.")
        else {
            return message
        }
        message += """
        . Selected SAM3 asset '\(assetName)' is a single-architecture compiled model. \
        Re-export SAM3 and use sam3_float16.aimodel, or compile sam3_float16_source.aimodel \
        for GPU/all supported architectures and update metadata.json assets.main.
        """
        return message
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
        if let resourceRoot = bundle.resourceURL,
           isModelBundle(resourceRoot) {
            return resourceRoot
        }
        return nil
    }

    private nonisolated static func assetName(in resourcesURL: URL?) -> String? {
        guard let resourcesURL else { return nil }
        let metadataURL = resourcesURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelBundleMetadata.self, from: data)
        else {
            return resourcesURL.pathExtension.isEmpty ? nil : resourcesURL.lastPathComponent
        }
        return metadata.assets["main"]
    }

    private nonisolated static func resourceName(in resourcesURL: URL?) -> String? {
        guard let resourcesURL else { return nil }
        let metadataURL = resourcesURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelBundleMetadata.self, from: data)
        else {
            return resourcesURL.lastPathComponent
        }
        if resourcesURL.lastPathComponent == "Resources" {
            return metadata.name
        }
        return resourcesURL.lastPathComponent
    }

    private nonisolated static func isModelBundle(_ url: URL) -> Bool {
        guard let assetName = assetName(in: url) else { return false }
        let assetURL = url.appendingPathComponent(assetName)
        let tokenizerURL = url.appendingPathComponent("tokenizer.json")
        let nestedTokenizerURL = url.appendingPathComponent("tokenizer/tokenizer.json")
        return FileManager.default.fileExists(atPath: assetURL.path)
            && (FileManager.default.fileExists(atPath: tokenizerURL.path)
                || FileManager.default.fileExists(atPath: nestedTokenizerURL.path))
    }

    private nonisolated struct ModelBundleMetadata: Decodable {
        let name: String?
        let assets: [String: String]
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
