#if SAM3_MASK_BUILDER
import Darwin
import Foundation

@main
enum SAM3MaskBuilderMain {
    static func main() async {
        do {
            let request = try readRequest()
            let catalogURL = try resolveCatalogURL(from: request)
            let didStartAccess = catalogURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    catalogURL.stopAccessingSecurityScopedResource()
                }
            }

            let files = await scanCatalog(at: catalogURL)
            guard !files.isEmpty else {
                throw HelperError.noFilesFound(catalogURL.path)
            }

            let provider = CoreAISAM3Provider(
                resourcesURL: URL(fileURLWithPath: request.modelResourcesPath, isDirectory: true),
            )
            let actor = SubjectSegmentationActor(
                provider: provider,
                cache: SubjectMaskCache(),
                diskCache: SAM3MaskDiskCache(
                    cacheDirectory: URL(fileURLWithPath: request.maskCachePath, isDirectory: true),
                ),
                maxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
            )
            let pipeline = SAM3MaskGenerationPipeline(
                actor: actor,
                imageLoader: { file in
                    await ZoomPreviewHandler.loadExtractedJPGPreview(for: file.url)
                },
            )

            _ = try await pipeline.generate(files: files) { event in
                emit(event)
            }

            await waitForParentToExit(pid: request.parentProcessID)
            relaunchRawCull(at: request.rawCullAppPath)
        } catch is CancellationError {
            emit(.failed("SAM3 mask creation was cancelled."))
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private nonisolated static func readRequest() throws -> SAM3MaskBuildRequest {
        let args = CommandLine.arguments
        guard let requestIndex = args.firstIndex(of: "--request"),
              args.indices.contains(args.index(after: requestIndex))
        else {
            throw HelperError.missingRequestPath
        }
        let url = URL(fileURLWithPath: args[args.index(after: requestIndex)])
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SAM3MaskBuildRequest.self, from: data)
    }

    private nonisolated static func resolveCatalogURL(from request: SAM3MaskBuildRequest) throws -> URL {
        var stale = false
        do {
            return try URL(
                resolvingBookmarkData: request.catalogBookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            )
        } catch {
            return URL(fileURLWithPath: request.catalogPath, isDirectory: true)
        }
    }

    private nonisolated static func scanCatalog(at url: URL) async -> [FileItem] {
        let discovered = await DiscoverFiles().discoverFiles(at: url, recursive: false)
        let keys: Set<URLResourceKey> = [.nameKey, .fileSizeKey, .contentModificationDateKey]
        let files = discovered.map { fileURL in
            let values = try? fileURL.resourceValues(forKeys: keys)
            return FileItem(
                url: fileURL,
                name: values?.name ?? fileURL.lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                dateModified: values?.contentModificationDate ?? Date(),
                exifData: nil,
                afFocusNormalized: nil,
            )
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func emit(_ event: SAM3MaskBuildEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private nonisolated static func waitForParentToExit(pid: Int32) async {
        guard pid > 0 else { return }
        while kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private nonisolated static func relaunchRawCull(at appPath: String) {
        guard !appPath.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        try? process.run()
    }
}

private enum HelperError: LocalizedError {
    case missingRequestPath
    case noFilesFound(String)

    var errorDescription: String? {
        switch self {
        case .missingRequestPath:
            "Missing --request argument."

        case let .noFilesFound(path):
            "No supported RAW files were found in catalog: \(path)"
        }
    }
}
#endif
