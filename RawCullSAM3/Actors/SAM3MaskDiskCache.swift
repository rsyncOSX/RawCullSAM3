import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

actor SAM3MaskDiskCache {
    private static let cacheKeyVersion = "v1-sam3mask"

    let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        let folder: URL
        if let cacheDirectory {
            folder = cacheDirectory
        } else {
            let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            folder = paths[0].appendingPathComponent("no.blogspot.RawCull/SAM3Masks")
        }
        self.cacheDirectory = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger.process.warning("SAM3MaskDiskCache: Failed to create directory \(folder): \(error)")
        }
    }

    func contains(
        for sourceURL: URL,
        prompt: SubjectSegmentationPrompt,
        modelVersion: String,
        inputMaxSide: Int,
    ) async -> Bool {
        let urls = cacheURLs(
            for: sourceURL,
            prompt: prompt,
            modelVersion: modelVersion,
            inputMaxSide: inputMaxSide,
        )
        return await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: urls.mask.path)
                && FileManager.default.fileExists(atPath: urls.metadata.path)
        }.value
    }

    func load(
        for sourceURL: URL,
        fileID: UUID,
        prompt: SubjectSegmentationPrompt,
        modelVersion: String,
        inputMaxSide: Int,
    ) async -> SubjectSegmentationResult? {
        let urls = cacheURLs(
            for: sourceURL,
            prompt: prompt,
            modelVersion: modelVersion,
            inputMaxSide: inputMaxSide,
        )
        let sourceIdentity = Self.sourceIdentity(for: sourceURL)

        return await Task.detached(priority: .userInitiated) {
            guard let metadataData = try? Data(contentsOf: urls.metadata),
                  let metadata = try? JSONDecoder().decode(SAM3MaskDiskCacheMetadata.self, from: metadataData),
                  metadata.matches(
                      sourceIdentity: sourceIdentity,
                      prompt: prompt,
                      modelVersion: modelVersion,
                      inputMaxSide: inputMaxSide,
                  ),
                  let mask = Self.loadPNG(from: urls.mask)
            else {
                return nil
            }

            let timing = SubjectSegmentationTiming(
                preprocessMilliseconds: nil,
                inferenceMilliseconds: nil,
                postprocessMilliseconds: nil,
                totalMilliseconds: 0,
            )
            let inputSize = CGSize(width: metadata.inputWidth, height: metadata.inputHeight)
            let outputSize = CGSize(width: mask.width, height: mask.height)
            let diagnostics = SubjectSegmentationDiagnostics(
                modelVersion: metadata.modelVersion,
                prompt: metadata.prompt,
                confidence: metadata.confidence,
                timing: timing,
                inputSize: inputSize,
                outputSize: outputSize,
                resourceName: nil,
                assetName: nil,
            )
            return SubjectSegmentationResult(
                fileID: fileID,
                requestID: UUID(),
                prompt: metadata.prompt,
                mask: mask,
                confidence: metadata.confidence,
                modelVersion: metadata.modelVersion,
                inputSize: inputSize,
                outputSize: outputSize,
                timing: timing,
                diagnostics: diagnostics,
            )
        }.value
    }

    func save(
        _ result: SubjectSegmentationResult,
        for sourceURL: URL,
        inputMaxSide: Int,
    ) async {
        guard let pngData = Self.pngData(from: result.mask) else {
            Logger.process.warning("SAM3MaskDiskCache: Failed to encode mask PNG for \(sourceURL.path)")
            return
        }
        let sourceIdentity = Self.sourceIdentity(for: sourceURL)
        let metadata = SAM3MaskDiskCacheMetadata(
            prompt: result.prompt,
            confidence: result.confidence,
            modelVersion: result.modelVersion,
            inputMaxSide: inputMaxSide,
            fileSize: sourceIdentity.fileSize,
            modificationDate: sourceIdentity.modificationDate,
            inputWidth: result.inputSize.width,
            inputHeight: result.inputSize.height,
            outputWidth: CGFloat(result.mask.width),
            outputHeight: CGFloat(result.mask.height),
        )
        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            Logger.process.warning("SAM3MaskDiskCache: Failed to encode metadata for \(sourceURL.path)")
            return
        }
        let urls = cacheURLs(
            for: sourceURL,
            prompt: result.prompt,
            modelVersion: result.modelVersion,
            inputMaxSide: inputMaxSide,
        )

        await Task.detached(priority: .background) {
            do {
                try pngData.write(to: urls.mask, options: .atomic)
                try metadataData.write(to: urls.metadata, options: .atomic)
            } catch {
                Logger.process.warning("SAM3MaskDiskCache: Failed to write mask cache for \(sourceURL.path): \(error)")
            }
        }.value
    }

    func getDiskCacheSize() async -> Int {
        let directory = cacheDirectory

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey]

            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: .skipsHiddenFiles,
            ) else { return 0 }

            var totalSize = 0
            for fileURL in urls {
                do {
                    let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                    if let size = values.totalFileAllocatedSize {
                        totalSize += size
                    }
                } catch {
                    Logger.process.warning("SAM3MaskDiskCache: Failed to get size for \(fileURL.path): \(error)")
                }
            }
            return totalSize
        }.value
    }

    func pruneCache(maxAgeInDays: Int = 90) async {
        let directory = cacheDirectory

        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.contentModificationDateKey]

            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: .skipsHiddenFiles,
            ) else { return }

            guard let expirationDate = Calendar.current.date(byAdding: .day, value: -maxAgeInDays, to: Date()) else {
                return
            }

            for fileURL in urls {
                do {
                    let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                    if let date = values.contentModificationDate, date < expirationDate {
                        try fileManager.removeItem(at: fileURL)
                    }
                } catch {
                    Logger.process.warning("SAM3MaskDiskCache: Failed to delete \(fileURL.path): \(error)")
                }
            }
        }.value
    }

    func removeAll() async {
        let directory = cacheDirectory

        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles,
            ) else { return }

            for fileURL in urls {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    Logger.process.warning("SAM3MaskDiskCache: Failed to delete \(fileURL.path): \(error)")
                }
            }
        }.value
    }

    private func cacheURLs(
        for sourceURL: URL,
        prompt: SubjectSegmentationPrompt,
        modelVersion: String,
        inputMaxSide: Int,
    ) -> (mask: URL, metadata: URL) {
        let standardizedPath = sourceURL.standardized.path
        let rawKey = "\(Self.cacheKeyVersion):\(standardizedPath):\(prompt.rawValue):\(modelVersion):\(inputMaxSide)"
        let digest = Insecure.MD5.hash(data: Data(rawKey.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let baseURL = cacheDirectory.appendingPathComponent(hash)
        return (
            mask: baseURL.appendingPathExtension("png"),
            metadata: baseURL.appendingPathExtension("json")
        )
    }

    nonisolated static func pngData(from cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil,
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private nonisolated static func loadPNG(from url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let decodeOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions) else {
            return nil
        }
        CGImageSourceRemoveCacheAtIndex(imageSource, 0)
        return cgImage
    }

    private nonisolated static func sourceIdentity(for sourceURL: URL) -> SAM3MaskSourceIdentity {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        return SAM3MaskSourceIdentity(
            fileSize: (attributes?[.size] as? NSNumber).map { $0.int64Value },
            modificationDate: attributes?[.modificationDate] as? Date,
        )
    }
}

nonisolated struct SAM3MaskDiskCacheMetadata: Codable, Equatable {
    let prompt: SubjectSegmentationPrompt
    let confidence: Float
    let modelVersion: String
    let inputMaxSide: Int
    let fileSize: Int64?
    let modificationDate: Date?
    let inputWidth: CGFloat
    let inputHeight: CGFloat
    let outputWidth: CGFloat
    let outputHeight: CGFloat

    func matches(
        sourceIdentity: SAM3MaskSourceIdentity,
        prompt: SubjectSegmentationPrompt,
        modelVersion: String,
        inputMaxSide: Int,
    ) -> Bool {
        self.prompt == prompt
            && self.modelVersion == modelVersion
            && self.inputMaxSide == inputMaxSide
            && fileSize == sourceIdentity.fileSize
            && modificationDate == sourceIdentity.modificationDate
    }
}

nonisolated struct SAM3MaskSourceIdentity: Equatable {
    let fileSize: Int64?
    let modificationDate: Date?
}
