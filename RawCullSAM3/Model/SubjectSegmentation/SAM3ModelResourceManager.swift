import Foundation

nonisolated enum SAM3ModelStatus: Equatable {
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
            "SAM 3 model resources are available at \(url.path)"

        case .missing:
            "SAM 3 model resources are not installed. Download support will be added later."

        case let .invalid(url, reason):
            "SAM 3 model resources were found at \(url.path), but \(reason)"
        }
    }
}

nonisolated struct SAM3ModelResourceManager {
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

    static func modelStatus() -> SAM3ModelStatus {
        Self().modelStatus()
    }

    static func validateModelBundle(at url: URL) -> Bool {
        Self().validateModelBundle(at: url)
    }

    func installedModelURL() -> URL? {
        modelStatus().modelURL
    }

    func modelStatus() -> SAM3ModelStatus {
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
            .appendingPathComponent("SAM3", isDirectory: true)
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
        if let url = bundle.url(forResource: "SAM3", withExtension: nil, subdirectory: "Models") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "SAM3", withExtension: nil, subdirectory: "Resources/Models") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "SAM3", withExtension: nil) {
            candidates.append(url)
        }
        if let resourceRoot = bundle.resourceURL {
            candidates.append(
                resourceRoot
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent("SAM3", isDirectory: true),
            )
            candidates.append(resourceRoot.appendingPathComponent("SAM3", isDirectory: true))
            if validateModelBundle(at: resourceRoot) {
                candidates.append(resourceRoot)
            }
        }
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
