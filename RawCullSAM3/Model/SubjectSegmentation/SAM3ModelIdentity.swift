import Foundation

nonisolated enum SAM3ModelIdentity {
    static let fallbackModelVersion = "coreai-sam3-local"

    static func modelVersion(resourcesURL: URL? = SAM3ModelResourceManager.installedModelURL()) -> String {
        guard let resourcesURL,
              let assetName = assetName(in: resourcesURL),
              !assetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallbackModelVersion
        }

        guard let metadata = metadata(in: resourcesURL),
              let name = metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return "\(fallbackModelVersion):\(assetName)"
        }

        return "\(fallbackModelVersion):\(name):\(assetName)"
    }

    static func assetName(in resourcesURL: URL?) -> String? {
        guard let resourcesURL else { return nil }
        guard let metadata = metadata(in: resourcesURL) else {
            return resourcesURL.pathExtension.isEmpty ? nil : resourcesURL.lastPathComponent
        }
        return metadata.assets["main"]
    }

    static func resourceName(in resourcesURL: URL?) -> String? {
        guard let resourcesURL else { return nil }
        guard let metadata = metadata(in: resourcesURL) else {
            return resourcesURL.lastPathComponent
        }
        if resourcesURL.lastPathComponent == "Resources" {
            return metadata.name
        }
        return resourcesURL.lastPathComponent
    }

    private static func metadata(in resourcesURL: URL) -> ModelBundleMetadata? {
        let metadataURL = resourcesURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(ModelBundleMetadata.self, from: data)
    }

    private struct ModelBundleMetadata: Decodable {
        let name: String?
        let assets: [String: String]
    }
}
