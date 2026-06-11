import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ExternalSAM3Provider: SubjectSegmentationProvider {
    let endpoint: URL
    let timeoutSeconds: TimeInterval
    let modelVersion: String

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:8765/v1/segment")!,
        timeoutSeconds: TimeInterval = 120,
        modelVersion: String = "external-sam3",
    ) {
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
        self.modelVersion = modelVersion
    }

    func segment(_ request: SubjectSegmentationRequest) async throws -> SubjectSegmentationResult {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(HelperRequest(from: request))

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard !Task.isCancelled else { throw SubjectSegmentationError.cancelled }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else {
                throw SubjectSegmentationError.helperUnavailable
            }
            let helperResponse = try JSONDecoder().decode(HelperResponse.self, from: data)
            return try decode(helperResponse, for: request)
        } catch let error as SubjectSegmentationError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw SubjectSegmentationError.timeout

            case .cancelled:
                throw SubjectSegmentationError.cancelled

            default:
                throw SubjectSegmentationError.helperUnavailable
            }
        } catch {
            throw SubjectSegmentationError.decodeFailure
        }
    }

    private func decode(
        _ response: HelperResponse,
        for request: SubjectSegmentationRequest,
    ) throws -> SubjectSegmentationResult {
        guard response.requestID == request.requestID.uuidString else {
            throw SubjectSegmentationError.staleResponse
        }
        if let error = response.error {
            throw SubjectSegmentationError.helperError(error)
        }
        guard let bestMask = response.masks.max(by: { $0.score < $1.score }) else {
            throw SubjectSegmentationError.noMask
        }
        guard let data = Data(base64Encoded: bestMask.pngBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw SubjectSegmentationError.decodeFailure
        }

        let timing = SubjectSegmentationTiming(
            preprocessMilliseconds: response.timingMilliseconds?.preprocess,
            inferenceMilliseconds: response.timingMilliseconds?.inference,
            postprocessMilliseconds: response.timingMilliseconds?.postprocess,
            totalMilliseconds: response.timingMilliseconds?.total,
        )
        let outputSize = CGSize(width: mask.width, height: mask.height)
        let diagnostics = SubjectSegmentationDiagnostics(
            modelVersion: response.modelVersion,
            prompt: request.prompt,
            confidence: bestMask.score,
            timing: timing,
            inputSize: request.inputSize,
            outputSize: outputSize,
            resourceName: endpoint.host(),
            assetName: endpoint.lastPathComponent,
        )

        return SubjectSegmentationResult(
            fileID: request.fileID,
            requestID: request.requestID,
            prompt: request.prompt,
            mask: mask,
            confidence: bestMask.score,
            modelVersion: response.modelVersion,
            inputSize: request.inputSize,
            outputSize: outputSize,
            timing: timing,
            diagnostics: diagnostics,
        )
    }
}

private nonisolated struct HelperRequest: Encodable {
    let requestID: String
    let fileID: String
    let prompt: String
    let maxSide: Int
    let imageBase64: String
    let imageFormat: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case fileID = "file_id"
        case prompt
        case maxSide = "max_side"
        case imageBase64 = "image_base64"
        case imageFormat = "image_format"
    }

    init(from request: SubjectSegmentationRequest) {
        requestID = request.requestID.uuidString
        fileID = request.fileID.uuidString
        prompt = request.prompt.rawValue
        maxSide = request.maxSide
        imageBase64 = request.imageData.base64EncodedString()
        imageFormat = request.imageFormat
    }
}

private nonisolated struct HelperResponse: Decodable {
    let requestID: String
    let modelVersion: String
    let masks: [HelperMask]
    let timingMilliseconds: HelperTiming?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case modelVersion = "model_version"
        case masks
        case timingMilliseconds = "timing_ms"
        case error
    }
}

private nonisolated struct HelperMask: Decodable {
    let pngBase64: String
    let score: Float
    let boxXYXY: [Float]?

    enum CodingKeys: String, CodingKey {
        case pngBase64 = "png_base64"
        case score
        case boxXYXY = "box_xyxy"
    }
}

private nonisolated struct HelperTiming: Decodable {
    let preprocess: Double?
    let inference: Double?
    let postprocess: Double?
    let total: Double?
}
