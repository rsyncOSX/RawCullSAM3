import CoreGraphics
import Foundation

nonisolated enum SubjectSegmentationPrompt: String, CaseIterable, Codable, Identifiable {
    case subject
    case person
    case bird
    case deer
    case animal
    case car

    nonisolated var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .subject: "Subject"
        case .person: "Person"
        case .bird: "Bird"
        case .deer: "Deer"
        case .animal: "Animal"
        case .car: "Car"
        }
    }

    nonisolated var query: String {
        switch self {
        case .subject: "subject"
        case .person: "person"
        case .bird: "bird"
        case .deer: "deer"
        case .animal: "animal"
        case .car: "car"
        }
    }
}

nonisolated struct SubjectSegmentationTiming: Equatable {
    let preprocessMilliseconds: Double?
    let inferenceMilliseconds: Double?
    let postprocessMilliseconds: Double?
    let totalMilliseconds: Double?
}

nonisolated struct SubjectSegmentationDiagnostics: Equatable {
    let modelVersion: String
    let prompt: SubjectSegmentationPrompt
    let confidence: Float
    let timing: SubjectSegmentationTiming
    let inputSize: CGSize
    let outputSize: CGSize
    let resourceName: String?
    let assetName: String?
}

nonisolated struct SubjectSegmentationResult {
    let fileID: UUID
    let requestID: UUID
    let prompt: SubjectSegmentationPrompt
    let mask: CGImage
    let confidence: Float
    let modelVersion: String
    let inputSize: CGSize
    let outputSize: CGSize
    let timing: SubjectSegmentationTiming
    let diagnostics: SubjectSegmentationDiagnostics
}

nonisolated enum SubjectSegmentationError: Error, Equatable {
    case helperUnavailable
    case timeout
    case noMask
    case decodeFailure
    case cancelled
    case staleResponse
    case helperError(String)

    nonisolated var displayMessage: String {
        switch self {
        case .helperUnavailable:
            "Core AI SAM3 unavailable"

        case .timeout:
            "Core AI SAM3 timed out"

        case .noMask:
            "No Core AI mask found"

        case .decodeFailure:
            "Could not decode Core AI mask"

        case .cancelled:
            "Core AI SAM3 request cancelled"

        case .staleResponse:
            "Ignored stale Core AI SAM3 result"

        case let .helperError(message):
            message.isEmpty ? "Core AI SAM3 failed" : message
        }
    }
}

nonisolated struct SubjectSegmentationRequest {
    let requestID: UUID
    let fileID: UUID
    let prompt: SubjectSegmentationPrompt
    let image: CGImage
    let imageData: Data
    let imageFormat: String
    let inputSize: CGSize
    let outputSize: CGSize
    let maxSide: Int
}

nonisolated protocol SubjectSegmentationProvider: Sendable {
    var modelVersion: String { get }

    func segment(_ request: SubjectSegmentationRequest) async throws -> SubjectSegmentationResult
}

nonisolated struct SubjectMaskCacheKey: Hashable {
    let fileID: UUID
    let prompt: SubjectSegmentationPrompt
    let modelVersion: String
    let inputMaxSide: Int
    let fileSize: Int64?
    let modificationDate: Date?
}

nonisolated struct SubjectMaskCacheEntry {
    let result: SubjectSegmentationResult
}
