import Foundation

nonisolated enum CLIPModelStatus: Equatable {
    case installed(URL)
    case missing
    case invalid(URL, String)

    var modelURL: URL? {
        if case let .installed(url) = self {
            return url
        }
        return nil
    }

    var isInstalled: Bool {
        modelURL != nil
    }

    var displayTitle: String {
        switch self {
        case .installed: "Installed"
        case .missing: "Missing"
        case .invalid: "Invalid"
        }
    }

    var displayMessage: String {
        switch self {
        case let .installed(url):
            "CLIP model resources are available at \(url.path)"

        case .missing:
            "CLIP model resources are not installed. Similarity indexing will use Vision feature prints until CLIP is available."

        case let .invalid(url, reason):
            "CLIP model resources were found at \(url.path), but \(reason)"
        }
    }
}

nonisolated struct CLIPModelResourceManager {
    let installedModelDirectory: URL
    let bundle: Bundle
    let allowsBundledFallback: Bool

    init(
        installedModelDirectory: URL = Self.defaultInstalledModelDirectory(),
        bundle: Bundle = .main,
        allowsBundledFallback: Bool = Self.defaultAllowsBundledFallback,
    ) {
        self.installedModelDirectory = installedModelDirectory
        self.bundle = bundle
        self.allowsBundledFallback = allowsBundledFallback
    }

    static func installedModelURL() -> URL? {
        Self().installedModelURL()
    }

    static func cacheIdentifier(for modelURL: URL?) -> String? {
        guard let modelURL else { return nil }
        let metadataURL = modelURL.appendingPathComponent("metadata.json")
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        else {
            return modelURL.standardizedFileURL.path
        }

        let name = object["name"] as? String ?? ""
        let sourceModel = object["source_model"] as? String ?? ""
        let metadataVersion = object["metadata_version"] as? String ?? ""
        let assets = object["assets"] as? [String: String]
        let mainAsset = assets?["main"] ?? ""
        let assetURL = modelURL.appendingPathComponent(mainAsset)
        let attributes = try? FileManager.default.attributesOfItem(atPath: assetURL.path)
        let assetSize = attributes?[.size] as? NSNumber
        let assetModified = attributes?[.modificationDate] as? Date

        return [
            name,
            sourceModel,
            metadataVersion,
            mainAsset,
            assetSize?.stringValue ?? "",
            assetModified.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }

    func installedModelURL() -> URL? {
        modelStatus().modelURL
    }

    func modelStatus() -> CLIPModelStatus {
        switch validateModelBundleDetailed(at: installedModelDirectory) {
        case .valid:
            return .installed(installedModelDirectory)

        case .missing:
            break

        case let .invalid(reason):
            return .invalid(installedModelDirectory, reason)
        }

        guard allowsBundledFallback else {
            return .missing
        }

        for candidate in bundledCandidates() {
            switch validateModelBundleDetailed(at: candidate) {
            case .valid:
                return .installed(candidate)

            case .missing:
                continue

            case let .invalid(reason):
                return .invalid(candidate, reason)
            }
        }
        return .missing
    }

    func validateModelBundle(at url: URL) -> Bool {
        validateModelBundleDetailed(at: url) == .valid
    }

    static func defaultInstalledModelDirectory(
        fileManager: FileManager = .default,
    ) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("RawCullSAM3", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("CLIP", isDirectory: true)
    }

    private static var defaultAllowsBundledFallback: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private func bundledCandidates() -> [URL] {
        var candidates: [URL] = []
        if let url = bundle.url(forResource: "CLIP", withExtension: nil, subdirectory: "Models") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "CLIP", withExtension: nil, subdirectory: "Resources/Models") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "CLIP", withExtension: nil) {
            candidates.append(url)
        }
        if let resourceRoot = bundle.resourceURL {
            candidates.append(
                resourceRoot
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent("CLIP", isDirectory: true),
            )
            candidates.append(resourceRoot.appendingPathComponent("CLIP", isDirectory: true))
        }
        #if DEBUG
            candidates.append(
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("RawCullSAM3", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent("CLIP", isDirectory: true),
            )
        #endif
        return candidates
    }

    private func validateModelBundleDetailed(at url: URL) -> ValidationResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return .invalid("it is not a folder.")
        }

        let metadataURL = url.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return .invalid("metadata.json is missing.")
        }
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModelBundleMetadata.self, from: metadataData)
        else {
            return .invalid("metadata.json could not be decoded.")
        }
        guard let assetName = metadata.assets["main"],
              !assetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalid("metadata.json does not define assets.main.")
        }

        let tokenizerURL = url.appendingPathComponent("tokenizer/tokenizer.json")
        guard fileManager.fileExists(atPath: tokenizerURL.path) else {
            return .invalid("tokenizer/tokenizer.json is missing.")
        }

        let assetURL = url.appendingPathComponent(assetName)
        guard fileManager.fileExists(atPath: assetURL.path) else {
            return .invalid("\(assetName) is missing.")
        }

        return .valid
    }

    private enum ValidationResult: Equatable {
        case valid
        case missing
        case invalid(String)
    }

    private struct ModelBundleMetadata: Decodable {
        let assets: [String: String]
    }
}
