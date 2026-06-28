import AppKit
import Foundation

@MainActor
final class SAM3MaskHelperController {
    private let modelResourceManager: SAM3ModelResourceManager
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var requestURL: URL?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private let decoder = JSONDecoder()

    init(modelResourceManager: SAM3ModelResourceManager = SAM3ModelResourceManager()) {
        self.modelResourceManager = modelResourceManager
    }

    func start(
        catalogURL: URL,
        targetFiles: [FileItem],
        onEvent: @escaping @MainActor (SAM3MaskBuildEvent) -> Void,
        onExit: @escaping @MainActor (Int32, String?) -> Void,
    ) throws {
        cancel()

        let helperURL = try Self.helperExecutableURL()
        let requestURL = try writeRequest(for: catalogURL, targetFiles: targetFiles)
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = helperURL
        process.arguments = ["--request", requestURL.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consume(data, onEvent: onEvent)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.errorBuffer.append(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.finish(exitCode: process.terminationStatus, onExit: onExit)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: requestURL)
            throw error
        }

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.requestURL = requestURL
    }

    func cancel() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        cleanupRequestFile()
        process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
    }

    private func consume(
        _ data: Data,
        onEvent: @escaping @MainActor (SAM3MaskBuildEvent) -> Void,
    ) {
        outputBuffer.append(data)
        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty,
                  let event = try? decoder.decode(SAM3MaskBuildEvent.self, from: Data(lineData))
            else { continue }
            onEvent(event)
        }
    }

    private func finish(
        exitCode: Int32,
        onExit: @escaping @MainActor (Int32, String?) -> Void,
    ) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        let errorText = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupRequestFile()
        process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        onExit(exitCode, errorText?.isEmpty == false ? errorText : nil)
    }

    private func cleanupRequestFile() {
        if let requestURL {
            try? FileManager.default.removeItem(at: requestURL)
        }
        requestURL = nil
    }

    private static func helperExecutableURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        let bundled = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("RawCullSAM3MaskBuilder")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let bundledExecutable = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RawCullSAM3MaskBuilder")
        if FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
            return bundledExecutable
        }

        let sibling = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("RawCullSAM3MaskBuilder")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        throw HelperControllerError.helperNotFound
    }

    private func writeRequest(for catalogURL: URL, targetFiles: [FileItem]) throws -> URL {
        let request = try Self.makeRequest(
            for: catalogURL,
            targetFiles: targetFiles,
            modelResourceManager: modelResourceManager,
        )
        let requestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawCullSAM3MaskBuilder-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL, options: .atomic)
        return requestURL
    }

    static func makeRequest(
        for catalogURL: URL,
        targetFiles: [FileItem],
        modelResourceManager: SAM3ModelResourceManager = SAM3ModelResourceManager(),
    ) throws -> SAM3MaskBuildRequest {
        guard let modelResourcesURL = modelResourceManager.installedModelURL() else {
            throw HelperControllerError.modelResourcesNotFound
        }
        let selectedFilePaths = targetFiles.map { $0.url.standardizedFileURL.path }
        return try SAM3MaskBuildRequest(
            catalogBookmark: catalogURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            ),
            catalogPath: catalogURL.path,
            modelResourcesPath: modelResourcesURL.path,
            maskCachePath: SharedMemoryCache.shared.sam3MaskDiskCache.cacheDirectory.path,
            rawCullAppPath: Bundle.main.bundleURL.path,
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            selectedFilePaths: selectedFilePaths,
        )
    }
}

private enum HelperControllerError: LocalizedError {
    case helperNotFound
    case modelResourcesNotFound

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            "RawCullSAM3MaskBuilder was not found in the app bundle or build products directory."

        case .modelResourcesNotFound:
            "SAM3 model resources were not found in RawCull."
        }
    }
}
