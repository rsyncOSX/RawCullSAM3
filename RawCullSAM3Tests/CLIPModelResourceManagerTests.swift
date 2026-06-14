import Foundation
@testable import RawCullSAM3
import Testing

struct CLIPModelResourceManagerTests {
    @Test
    func `valid installed model bundle is reported as installed`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("CLIP", isDirectory: true)
        try makeModelBundle(at: modelURL)

        let manager = CLIPModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        #expect(manager.installedModelURL() == modelURL)
        #expect(manager.modelStatus() == .installed(modelURL))
        #expect(manager.validateModelBundle(at: modelURL))
    }

    @Test
    func `missing installed model bundle is reported as missing`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("MissingCLIP", isDirectory: true)
        let manager = CLIPModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        #expect(manager.installedModelURL() == nil)
        #expect(manager.modelStatus() == .missing)
        #expect(!manager.validateModelBundle(at: modelURL))
    }

    @Test
    func `missing tokenizer is reported as invalid`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("CLIP", isDirectory: true)
        try makeModelBundle(at: modelURL, includeTokenizer: false)
        let manager = CLIPModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        guard case let .invalid(url, reason) = manager.modelStatus() else {
            Issue.record("Expected invalid model status")
            return
        }
        #expect(url == modelURL)
        #expect(reason.contains("tokenizer/tokenizer.json"))
        #expect(!manager.validateModelBundle(at: modelURL))
    }

    @Test
    func `missing metadata asset is reported as invalid`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("CLIP", isDirectory: true)
        try makeModelBundle(at: modelURL, includeAsset: false)
        let manager = CLIPModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        guard case let .invalid(url, reason) = manager.modelStatus() else {
            Issue.record("Expected invalid model status")
            return
        }
        #expect(url == modelURL)
        #expect(reason.contains("clip-vit-base-patch32_float16_static.aimodel"))
        #expect(!manager.validateModelBundle(at: modelURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPModelResourceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModelBundle(
        at url: URL,
        includeTokenizer: Bool = true,
        includeAsset: Bool = true,
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let assetName = "clip-vit-base-patch32_float16_static.aimodel"
        let metadata = #"{"assets":{"main":"\#(assetName)"}}"#
        try Data(metadata.utf8).write(to: url.appendingPathComponent("metadata.json"))

        if includeTokenizer {
            let tokenizerDirectory = url.appendingPathComponent("tokenizer", isDirectory: true)
            try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: tokenizerDirectory.appendingPathComponent("tokenizer.json"))
        }

        if includeAsset {
            try Data("model".utf8).write(to: url.appendingPathComponent(assetName))
        }
    }
}
