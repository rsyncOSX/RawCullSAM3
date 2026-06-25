import Foundation
import RawCullCore

nonisolated struct BurstGroupSignature: Codable, Hashable {
    let memberKeys: [String]

    init(memberKeys: [String]) {
        self.memberKeys = memberKeys
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    init?(files: [FileItem], catalog: URL?) {
        let keys = files.map { Self.memberKey(for: $0, catalog: catalog) }
        guard !keys.isEmpty else { return nil }
        self.init(memberKeys: keys)
    }

    static func memberKey(for file: FileItem, catalog: URL?) -> String {
        guard let catalog else { return file.name }

        let catalogPath = catalog.standardizedFileURL.path
        let filePath = file.url.standardizedFileURL.path
        let prefix = catalogPath.hasSuffix("/") ? catalogPath : catalogPath + "/"

        guard filePath.hasPrefix(prefix) else { return file.name }
        let relativePath = String(filePath.dropFirst(prefix.count))
        return relativePath.isEmpty ? file.name : relativePath
    }
}
