import CoreAI
import CoreAIImageSegmenter
import CoreGraphics
import Foundation
import OSLog

nonisolated struct CLIPImageAnalysis {
    let embedding: [Float]
    let label: String?
    let confidence: Float?
}

actor CoreAICLIPProvider {
    private let resourcesURL: URL?
    private var loadedModel: LoadedCLIPModel?
    private var labelEmbeddings: [(label: String, embedding: [Float])]?

    init(resourcesURL: URL? = CLIPModelResourceManager.installedModelURL()) {
        self.resourcesURL = resourcesURL
    }

    func imageEmbedding(for image: CGImage) async throws -> [Float] {
        let model = try await loadModel()
        return try await imageEmbedding(for: image, model: model)
    }

    func imageAnalysis(for image: CGImage) async throws -> CLIPImageAnalysis {
        let model = try await loadModel()
        let normalizedEmbedding = try await imageEmbedding(for: image, model: model)
        let labels = try await loadLabelEmbeddings(for: model)
        let best = Self.bestLabel(for: normalizedEmbedding, labels: labels)
        return CLIPImageAnalysis(
            embedding: normalizedEmbedding,
            label: best?.label,
            confidence: best?.confidence,
        )
    }

    private func imageEmbedding(
        for image: CGImage,
        model: LoadedCLIPModel,
    ) async throws -> [Float] {
        let imageInput = try Self.makeImageInput(
            image,
            descriptor: model.imageDescriptor,
        )
        var imageEmbedding: [Float]?
        let tokenInput = try Self.makeTokenInput(
            model.dummyTokens,
            descriptor: model.inputIDsDescriptor,
        )
        let attentionMaskInput = try Self.makeAttentionMaskInput(
            descriptor: model.attentionMaskDescriptor,
        )

        var outputs = try await model.function.run(
            inputs: [
                model.imageInputName: imageInput,
                model.inputIDsInputName: tokenInput,
                model.attentionMaskInputName: attentionMaskInput
            ],
        )
        if let embeddingOutput = outputs.remove(model.imageEmbedsOutputName)?.ndArray {
            imageEmbedding = Self.flattenAsFloat(embeddingOutput)
        }

        guard let values = imageEmbedding, !values.isEmpty else {
            throw CLIPProviderError.invalidModel("CLIP image embedding output is empty.")
        }
        return SimilarityEmbeddingEnvelope.normalized(values)
    }

    private func loadModel() async throws -> LoadedCLIPModel {
        if let loadedModel {
            return loadedModel
        }
        guard let resourcesURL else {
            throw CLIPProviderError.missingModel
        }

        let metadata = try Self.readMetadata(at: resourcesURL)
        guard let assetName = metadata.assets["main"] else {
            throw CLIPProviderError.invalidModel("metadata.json does not define assets.main.")
        }
        let modelURL = resourcesURL.appendingPathComponent(assetName)
        let tokenizer = try CLIPTokenizer(
            folder: resourcesURL.appendingPathComponent("tokenizer", isDirectory: true),
        )

        let model = try await AIModel(contentsOf: modelURL, options: Self.specializationOptions())
        guard let descriptor = model.functionDescriptor(for: "main") else {
            throw CLIPProviderError.invalidModel("Cannot find main function in CLIP model.")
        }
        guard let function = try model.loadFunction(named: "main") else {
            throw CLIPProviderError.invalidModel("Cannot load main function from CLIP model.")
        }

        let imageInputName = try Self.requiredInputName("pixel_values", in: descriptor.inputNames)
        let inputIDsInputName = try Self.requiredInputName("input_ids", in: descriptor.inputNames)
        let attentionMaskInputName = try Self.requiredInputName("attention_mask", in: descriptor.inputNames)
        let imageEmbedsOutputName = try Self.requiredOutputName("image_embeds", in: descriptor.outputNames)
        let logitsPerImageOutputName = try Self.requiredOutputName("logits_per_image", in: descriptor.outputNames)
        let textEmbedsOutputName = try Self.requiredOutputName("text_embeds", in: descriptor.outputNames)

        guard case let .ndArray(imageDescriptor) = descriptor.inputDescriptor(of: imageInputName),
              case let .ndArray(inputIDsDescriptor) = descriptor.inputDescriptor(of: inputIDsInputName),
              case let .ndArray(attentionMaskDescriptor) = descriptor.inputDescriptor(of: attentionMaskInputName)
        else {
            throw CLIPProviderError.invalidModel("CLIP inputs are not NDArrays.")
        }
        guard imageDescriptor.shape.count == 4,
              inputIDsDescriptor.shape.count == 2,
              attentionMaskDescriptor.shape.count == 2
        else {
            throw CLIPProviderError.invalidModel(
                "Unexpected CLIP input shapes: image=\(imageDescriptor.shape), input_ids=\(inputIDsDescriptor.shape), attention_mask=\(attentionMaskDescriptor.shape).",
            )
        }

        let textBatchSize = inputIDsDescriptor.shape[0]
        let sequenceLength = inputIDsDescriptor.shape[1]
        let dummyTokens = Array(
            repeating: tokenizer.encode("a photo", contextLength: sequenceLength),
            count: textBatchSize,
        )

        let loaded = LoadedCLIPModel(
            function: function,
            imageInputName: imageInputName,
            inputIDsInputName: inputIDsInputName,
            attentionMaskInputName: attentionMaskInputName,
            imageEmbedsOutputName: imageEmbedsOutputName,
            logitsPerImageOutputName: logitsPerImageOutputName,
            textEmbedsOutputName: textEmbedsOutputName,
            imageDescriptor: imageDescriptor,
            inputIDsDescriptor: inputIDsDescriptor,
            attentionMaskDescriptor: attentionMaskDescriptor,
            tokenizer: tokenizer,
            textBatchSize: textBatchSize,
            sequenceLength: sequenceLength,
            dummyTokens: dummyTokens,
        )
        loadedModel = loaded
        return loaded
    }

    private func loadLabelEmbeddings(
        for model: LoadedCLIPModel,
    ) async throws -> [(label: String, embedding: [Float])] {
        if let labelEmbeddings {
            return labelEmbeddings
        }

        var embeddings: [(label: String, embedding: [Float])] = []
        let imageInput = try Self.makeBlankImageInput(descriptor: model.imageDescriptor)
        let attentionMaskInput = try Self.makeAttentionMaskInput(descriptor: model.attentionMaskDescriptor)

        for batch in Self.labelPromptBatches(
            tokenizer: model.tokenizer,
            batchSize: model.textBatchSize,
            sequenceLength: model.sequenceLength,
        ) {
            let tokenInput = try Self.makeTokenInput(
                batch.tokens,
                descriptor: model.inputIDsDescriptor,
            )
            var outputs = try await model.function.run(
                inputs: [
                    model.imageInputName: imageInput,
                    model.inputIDsInputName: tokenInput,
                    model.attentionMaskInputName: attentionMaskInput
                ],
            )
            guard let textOutput = outputs.remove(model.textEmbedsOutputName)?.ndArray else {
                throw CLIPProviderError.invalidModel("CLIP output \(model.textEmbedsOutputName) is missing.")
            }
            let rows = Self.flattenRowsAsFloat(textOutput)
            for (index, label) in batch.labels.enumerated() where index < rows.count {
                embeddings.append((label, SimilarityEmbeddingEnvelope.normalized(rows[index])))
            }
        }

        labelEmbeddings = embeddings
        return embeddings
    }

    private nonisolated static func specializationOptions() -> SpecializationOptions {
        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = false
        return options
    }

    private nonisolated static func readMetadata(at resourcesURL: URL) throws -> ModelBundleMetadata {
        let metadataURL = resourcesURL.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(ModelBundleMetadata.self, from: data)
    }

    private nonisolated static func requiredInputName(
        _ preferredName: String,
        in names: [String],
    ) throws -> String {
        if names.contains(preferredName) {
            return preferredName
        }
        throw CLIPProviderError.invalidModel("CLIP input \(preferredName) is missing. Inputs: \(names).")
    }

    private nonisolated static func requiredOutputName(
        _ preferredName: String,
        in names: [String],
    ) throws -> String {
        if names.contains(preferredName) {
            return preferredName
        }
        throw CLIPProviderError.invalidModel("CLIP output \(preferredName) is missing. Outputs: \(names).")
    }

    private nonisolated static func makeImageInput(
        _ image: CGImage,
        descriptor: NDArrayDescriptor,
    ) throws -> NDArray {
        let shape = descriptor.shape
        let batchSize = shape[0]
        let channels = shape[1]
        let height = shape[2]
        let width = shape[3]
        guard batchSize == 1, channels == 3 else {
            throw CLIPProviderError.invalidModel("Expected CLIP image input shape [1, 3, H, W], got \(shape).")
        }
        let pixels = try preprocessCLIPImage(image, width: width, height: height)
        var array = NDArray(descriptor: descriptor)
        if descriptor.scalarType == .float16 {
            #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
                fillNDArray(&array, as: Float16.self, with: pixels.map(Float16.init))
            #else
                throw CLIPProviderError.invalidModel("Float16 CLIP input is not supported on this platform.")
            #endif
        } else {
            fillNDArray(&array, as: Float.self, with: pixels)
        }
        return array
    }

    private nonisolated static func makeBlankImageInput(
        descriptor: NDArrayDescriptor,
    ) throws -> NDArray {
        let shape = descriptor.shape
        let batchSize = shape[0]
        let channels = shape[1]
        let height = shape[2]
        let width = shape[3]
        guard batchSize == 1, channels == 3 else {
            throw CLIPProviderError.invalidModel("Expected CLIP image input shape [1, 3, H, W], got \(shape).")
        }
        let pixels = [Float](repeating: 0, count: channels * height * width)
        var array = NDArray(descriptor: descriptor)
        if descriptor.scalarType == .float16 {
            #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
                fillNDArray(&array, as: Float16.self, with: pixels.map(Float16.init))
            #else
                throw CLIPProviderError.invalidModel("Float16 CLIP input is not supported on this platform.")
            #endif
        } else {
            fillNDArray(&array, as: Float.self, with: pixels)
        }
        return array
    }

    private nonisolated static func makeTokenInput(
        _ tokens: [[Int32]],
        descriptor: NDArrayDescriptor,
    ) throws -> NDArray {
        let batchSize = descriptor.shape[0]
        let sequenceLength = descriptor.shape[1]
        var array = NDArray(descriptor: descriptor)
        fillNDArray(&array, as: Int32.self, count: batchSize * sequenceLength) { index in
            let row = index / sequenceLength
            let column = index % sequenceLength
            guard row < tokens.count, column < tokens[row].count else {
                return CLIPTokenizer.eotTokenId
            }
            return tokens[row][column]
        }
        return array
    }

    private nonisolated static func makeAttentionMaskInput(
        descriptor: NDArrayDescriptor,
    ) throws -> NDArray {
        let batchSize = descriptor.shape[0]
        let sequenceLength = descriptor.shape[1]
        var array = NDArray(descriptor: descriptor)
        fillNDArray(&array, as: Int32.self, count: batchSize * sequenceLength) { _ in 1 }
        return array
    }

    private nonisolated static func labelPromptBatches(
        tokenizer: CLIPTokenizer,
        batchSize: Int,
        sequenceLength: Int,
    ) -> [CLIPPromptBatch] {
        let labels = Self.zeroShotLabels
        return stride(from: 0, to: labels.count, by: batchSize).map { start in
            let end = min(start + batchSize, labels.count)
            let batchLabels = Array(labels[start ..< end])
            var prompts = batchLabels.map { "a photo of \($0.prompt)" }
            if prompts.count < batchSize {
                prompts.append(contentsOf: Array(repeating: "a photo", count: batchSize - prompts.count))
            }
            return CLIPPromptBatch(
                labels: batchLabels.map(\.display),
                tokens: prompts.map { tokenizer.encode($0, contextLength: sequenceLength) },
            )
        }
    }

    private nonisolated static func bestLabel(
        for imageEmbedding: [Float],
        labels: [(label: String, embedding: [Float])],
    ) -> (label: String, confidence: Float)? {
        let scoredLabels = labels.compactMap { label, embedding -> (label: String, score: Float)? in
            guard imageEmbedding.count == embedding.count else { return nil }
            let score = zip(imageEmbedding, embedding).reduce(Float(0)) { partial, pair in
                partial + pair.0 * pair.1
            }
            return (label, score)
        }
        guard let best = scoredLabels.max(by: { $0.score < $1.score }) else { return nil }
        let maxScore = scoredLabels.map(\.score).max() ?? best.score
        let expScores = scoredLabels.map { exp(Double($0.score - maxScore)) }
        let denominator = expScores.reduce(0, +)
        guard denominator.isFinite, denominator > 0 else {
            return (best.label, 0)
        }
        let bestIndex = scoredLabels.firstIndex { $0.label == best.label && $0.score == best.score } ?? 0
        return (best.label, Float(expScores[bestIndex] / denominator))
    }

    private nonisolated static let zeroShotLabels: [CLIPZeroShotLabel] = [
        .init(display: "bird", prompt: "a bird"),
        .init(display: "animal", prompt: "an animal"),
        .init(display: "person", prompt: "a person"),
        .init(display: "dog", prompt: "a dog"),
        .init(display: "cat", prompt: "a cat"),
        .init(display: "horse", prompt: "a horse"),
        .init(display: "insect", prompt: "an insect"),
        .init(display: "flower", prompt: "a flower"),
        .init(display: "tree", prompt: "a tree"),
        .init(display: "landscape", prompt: "a landscape"),
        .init(display: "water", prompt: "water"),
        .init(display: "boat", prompt: "a boat"),
        .init(display: "car", prompt: "a car"),
        .init(display: "aircraft", prompt: "an aircraft"),
        .init(display: "building", prompt: "a building"),
        .init(display: "food", prompt: "food")
    ]

    private nonisolated static func preprocessCLIPImage(
        _ image: CGImage,
        width: Int,
        height: Int,
    ) throws -> [Float] {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &rgba,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              )
        else {
            throw CLIPProviderError.imagePreprocessingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let count = width * height
        var chw = [Float](repeating: 0, count: 3 * count)
        let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
        let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

        for pixel in 0 ..< count {
            let offset = pixel * bytesPerPixel
            let r = Float(rgba[offset]) / 255.0
            let g = Float(rgba[offset + 1]) / 255.0
            let b = Float(rgba[offset + 2]) / 255.0
            chw[pixel] = (r - mean[0]) / std[0]
            chw[count + pixel] = (g - mean[1]) / std[1]
            chw[2 * count + pixel] = (b - mean[2]) / std[2]
        }
        return chw
    }

    private nonisolated static func fillNDArray<T: BitwiseCopyable>(
        _ array: inout NDArray,
        as _: T.Type,
        with elements: some Collection<T>,
    ) {
        var view = array.mutableView(as: T.self)
        view.copyElements(fromContentsOf: elements)
    }

    private nonisolated static func fillNDArray<T: BitwiseCopyable>(
        _ array: inout NDArray,
        as _: T.Type,
        count: Int,
        using generator: (Int) -> T,
    ) {
        var view = array.mutableView(as: T.self)
        view.withUnsafeMutablePointer { pointer, _, _ in
            for index in 0 ..< count {
                pointer[index] = generator(index)
            }
        }
    }

    private nonisolated static func flattenAsFloat(_ array: NDArray) -> [Float] {
        switch array.scalarType {
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
            case .float16:
                return flattenNDArray(array, as: Float16.self)
        #endif

        case .float32:
            return flattenNDArray(array, as: Float.self)

        default:
            return []
        }
    }

    private nonisolated static func flattenRowsAsFloat(_ array: NDArray) -> [[Float]] {
        let values = flattenAsFloat(array)
        guard array.shape.count >= 2 else { return values.isEmpty ? [] : [values] }
        let rowCount = array.shape[0]
        guard rowCount > 0, values.count >= rowCount else { return [] }
        let rowSize = values.count / rowCount
        guard rowSize > 0 else { return [] }
        return (0 ..< rowCount).map { row in
            let start = row * rowSize
            return Array(values[start ..< (start + rowSize)])
        }
    }

    private nonisolated static func flattenNDArray<T: BinaryFloatingPoint & BitwiseCopyable>(
        _ array: NDArray,
        as _: T.Type,
    ) -> [Float] {
        let total = array.shape.reduce(1, *)
        var result = [Float](repeating: 0, count: total)
        array.view(as: T.self).withUnsafePointer { pointer, _, _ in
            for index in 0 ..< total {
                result[index] = Float(pointer[index])
            }
        }
        return result
    }

    private struct LoadedCLIPModel {
        let function: InferenceFunction
        let imageInputName: String
        let inputIDsInputName: String
        let attentionMaskInputName: String
        let imageEmbedsOutputName: String
        let logitsPerImageOutputName: String
        let textEmbedsOutputName: String
        let imageDescriptor: NDArrayDescriptor
        let inputIDsDescriptor: NDArrayDescriptor
        let attentionMaskDescriptor: NDArrayDescriptor
        let tokenizer: CLIPTokenizer
        let textBatchSize: Int
        let sequenceLength: Int
        let dummyTokens: [[Int32]]
    }

    private struct ModelBundleMetadata: Decodable {
        let assets: [String: String]
    }

    private struct CLIPZeroShotLabel {
        let display: String
        let prompt: String
    }

    private struct CLIPPromptBatch {
        let labels: [String]
        let tokens: [[Int32]]
    }
}

enum CLIPProviderError: Error, CustomStringConvertible {
    case missingModel
    case invalidModel(String)
    case imagePreprocessingFailed

    var description: String {
        switch self {
        case .missingModel:
            "CLIP model resources are not installed."

        case let .invalidModel(message):
            message

        case .imagePreprocessingFailed:
            "CLIP image preprocessing failed."
        }
    }
}
