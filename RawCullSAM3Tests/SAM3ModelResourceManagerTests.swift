import Foundation
import RawCullCore
import Testing
@testable import RawCullSAM3

struct SAM3ModelResourceManagerTests {
    @Test
    func `valid installed model bundle is reported as installed`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("SAM3", isDirectory: true)
        try makeModelBundle(at: modelURL)

        let manager = SAM3ModelResourceManager(
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
        let modelURL = root.appendingPathComponent("MissingSAM3", isDirectory: true)
        let manager = SAM3ModelResourceManager(
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
        let modelURL = root.appendingPathComponent("SAM3", isDirectory: true)
        try makeModelBundle(at: modelURL, includeTokenizer: false)
        let manager = SAM3ModelResourceManager(
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
        let modelURL = root.appendingPathComponent("SAM3", isDirectory: true)
        try makeModelBundle(at: modelURL, includeAsset: false)
        let manager = SAM3ModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        guard case let .invalid(url, reason) = manager.modelStatus() else {
            Issue.record("Expected invalid model status")
            return
        }
        #expect(url == modelURL)
        #expect(reason.contains("sam3_float16.aimodel"))
        #expect(!manager.validateModelBundle(at: modelURL))
    }

    @Test
    func `helper request uses resolved model path`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        let modelURL = root.appendingPathComponent("SAM3", isDirectory: true)
        try makeModelBundle(at: modelURL)
        let manager = SAM3ModelResourceManager(
            installedModelDirectory: modelURL,
            allowsBundledFallback: false,
        )

        let request = try SAM3MaskHelperController.makeRequest(
            for: catalogURL,
            modelResourceManager: manager,
        )

        #expect(request.catalogPath == catalogURL.path)
        #expect(request.modelResourcesPath == modelURL.path)
    }

    @Test
    func `helper request throws when model is missing`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        let manager = SAM3ModelResourceManager(
            installedModelDirectory: root.appendingPathComponent("MissingSAM3", isDirectory: true),
            allowsBundledFallback: false,
        )

        #expect(throws: Error.self) {
            try SAM3MaskHelperController.makeRequest(
                for: catalogURL,
                modelResourceManager: manager,
            )
        }
    }

    @Test
    @MainActor
    func `SAM3 mask helper launch is blocked when model is missing`() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.ARW")
        try Data("raw".utf8).write(to: sourceURL)
        let file = FileItem(
            url: sourceURL,
            name: "source.ARW",
            size: 3,
            dateModified: Date(),
            exifData: nil,
            afFocusNormalized: nil,
        )
        let viewModel = RawCullViewModel()
        viewModel.selectedSource = ARWSourceCatalog(name: "Missing Model", url: root)
        viewModel.files = [file]
        viewModel.filteredFiles = [file]
        viewModel.sam3ModelResourceManager = SAM3ModelResourceManager(
            installedModelDirectory: root.appendingPathComponent("MissingSAM3", isDirectory: true),
            allowsBundledFallback: false,
        )

        viewModel.startSAM3MaskCreationHelperForCatalog()

        #expect(viewModel.isCreatingSAM3Masks)
        #expect(viewModel.sam3MaskCreationStatusText.contains("Settings > AI"))
        #expect(viewModel.sam3MaskCreationProgress?.total == 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SAM3ModelResourceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModelBundle(
        at url: URL,
        includeTokenizer: Bool = true,
        includeAsset: Bool = true,
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let metadata = #"{"assets":{"main":"sam3_float16.aimodel"}}"#
        try Data(metadata.utf8).write(to: url.appendingPathComponent("metadata.json"))

        if includeTokenizer {
            let tokenizerDirectory = url.appendingPathComponent("tokenizer", isDirectory: true)
            try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: tokenizerDirectory.appendingPathComponent("tokenizer.json"))
        }

        if includeAsset {
            try Data("model".utf8).write(to: url.appendingPathComponent("sam3_float16.aimodel"))
        }
    }
}
