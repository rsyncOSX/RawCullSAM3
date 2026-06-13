import Foundation
import OSLog
import RawCullCore

/// Scans the SAM 3 disk cache for all files in the current catalog and
/// publishes a lightweight geometry and quality summary for each file.
///
/// Build is incremental: each file's entry is inserted into `inventory` as
/// soon as it is computed, so observers receive progressive updates.
/// No SAM 3 inference is triggered — the actor only reads existing cache entries.
actor SAM3MaskCatalogIndex {
    /// Per-file mask inventory, keyed by `FileItem.ID`.
    /// Published progressively as entries are computed.
    private(set) var inventory: [FileItem.ID: SAM3MaskInventoryEntry] = [:]

    private var buildTask: Task<Void, Never>?

    // MARK: - Public API

    /// Clears any in-flight build and resets the inventory.
    func reset() {
        buildTask?.cancel()
        buildTask = nil
        inventory = [:]
    }

    /// Starts a new incremental build for `files`, cancelling any prior run.
    /// Each entry is inserted into `inventory` on the actor as soon as it is ready.
    /// - Parameters:
    ///   - files: The current catalog file list.
    ///   - diskCache: The SAM 3 mask disk cache to query.
    ///   - onUpdate: Optional closure called on the caller's context after each
    ///               batch of entries is inserted (useful for `@MainActor` observers).
    func build(
        for files: [FileItem],
        diskCache: SAM3MaskDiskCache,
        onUpdate: (@MainActor @Sendable () -> Void)? = nil,
    ) {
        buildTask?.cancel()
        inventory = [:]

        buildTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runBuild(files: files, diskCache: diskCache, onUpdate: onUpdate)
        }
    }

    // MARK: - Private

    private func runBuild(
        files: [FileItem],
        diskCache: SAM3MaskDiskCache,
        onUpdate: (@MainActor @Sendable () -> Void)?,
    ) async {
        let batchSize = 20
        var batch: [(FileItem.ID, SAM3MaskInventoryEntry)] = []
        batch.reserveCapacity(batchSize)

        for file in files {
            guard !Task.isCancelled else { break }

            let entry = await computeEntry(for: file, diskCache: diskCache)
            batch.append((file.id, entry))

            if batch.count >= batchSize {
                let captured = batch
                for (id, e) in captured {
                    inventory[id] = e
                }
                batch.removeAll(keepingCapacity: true)
                if let onUpdate {
                    await onUpdate()
                }
            }
        }

        guard !Task.isCancelled else { return }

        if !batch.isEmpty {
            for (id, e) in batch {
                inventory[id] = e
            }
            if let onUpdate {
                await onUpdate()
            }
        }

        Logger.process.debugMessageOnly(
            "SAM3MaskCatalogIndex: built inventory for \(inventory.count) files",
        )
    }

    private func computeEntry(
        for file: FileItem,
        diskCache: SAM3MaskDiskCache,
    ) async -> SAM3MaskInventoryEntry {
        // Fast synchronous check — avoids spawning a detached task per file
        // when the cache directory is empty (common before any masks are built).
        guard await diskCache.metadataFileExists(
            for: file.url,
            prompt: SAM3SubjectMaskCacheReader.prompt,
            modelVersion: SAM3SubjectMaskCacheReader.modelVersion,
            inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        ) else {
            return .absent
        }

        guard let result = await SAM3SubjectMaskCacheReader.loadCachedMask(
            for: file,
            diskCache: diskCache,
        ) else {
            return .absent
        }

        let fileModDate = (try? FileManager.default
            .attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date)
        let cacheModDate = await diskCache.cacheModificationDate(
            for: file.url,
            prompt: SAM3SubjectMaskCacheReader.prompt,
            modelVersion: SAM3SubjectMaskCacheReader.modelVersion,
            inputMaxSide: SAM3SubjectMaskCacheReader.inputMaxSide,
        )

        return SAM3MaskInventoryEntry.geometry(
            from: result.mask,
            sourceModificationDate: fileModDate,
            cacheModificationDate: cacheModDate,
            confidence: result.confidence,
        )
    }
}
