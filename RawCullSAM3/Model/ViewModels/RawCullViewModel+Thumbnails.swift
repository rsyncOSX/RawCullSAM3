//
//  RawCullViewModel+Thumbnails.swift
//  RawCull
//

import AppKit
import CoreGraphics
import OSLog

extension RawCullViewModel {
    var sam3MaskCreationCandidateFiles: [FileItem] {
        sam3MaskCreationTargetFiles
    }

    var sam3MaskCreationCatalogFiles: [FileItem] {
        files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var sam3MaskCreationTargetFiles: [FileItem] {
        let orderedFiles = sam3MaskCreationOrderedFiles()
        if !selectedFileIDs.isEmpty {
            return orderedFiles.filter { selectedFileIDs.contains($0.id) }
        }

        guard case let .stars(rating) = ratingFilter,
              (2 ... 5).contains(rating)
        else { return [] }

        return orderedFiles.filter { getRating(for: $0) == rating }
    }

    var sam3MaskCreationTargetDescription: String {
        let count = sam3MaskCreationTargetFiles.count
        if !selectedFileIDs.isEmpty {
            return "\(count) selected thumbnail\(count == 1 ? "" : "s")"
        }
        if case let .stars(rating) = ratingFilter,
           (2 ... 5).contains(rating) {
            return "\(count) \(rating)-star file\(count == 1 ? "" : "s")"
        }
        return "no selected thumbnails or active 2-5 star filter"
    }

    func sam3MaskCreationOrderedFiles() -> [FileItem] {
        let visibleFiles = filteredFiles.isEmpty ? sam3MaskCreationCatalogFiles : filteredFiles
        var seenIDs = Set<FileItem.ID>()
        var orderedFiles: [FileItem] = []

        for file in visibleFiles {
            if seenIDs.insert(file.id).inserted {
                orderedFiles.append(file)
            }
        }

        for file in sam3MaskCreationCatalogFiles where seenIDs.insert(file.id).inserted {
            orderedFiles.append(file)
        }

        return orderedFiles
    }

    func fileHandler(_ update: Int) {
        progress = Double(update)
    }

    func maxfilesHandler(_ maxfiles: Int) {
        max = Double(maxfiles)
    }

    func estimatedTimeHandler(_ seconds: Int) {
        estimatedSeconds = seconds
    }

    func setMemoryPressureWarning(_ warning: Bool) {
        memoryPressureWarning = warning
    }

    func extractionNeeded() {
        creatingthumbnails = true
    }

    var selectedFilesForJPGExtraction: [FileItem] {
        if !selectedFileIDs.isEmpty {
            return filteredFiles.filter { selectedFileIDs.contains($0.id) }
        }

        guard let selectedFileID else { return [] }
        if let file = filteredFiles.first(where: { $0.id == selectedFileID }) {
            return [file]
        }
        return files.first(where: { $0.id == selectedFileID }).map { [$0] } ?? []
    }

    func presentExtractJPGsSheet() {
        guard !sources.isEmpty else { return }
        if extractJPGDestination == nil {
            extractJPGDestination = selectedSource ?? sources.first
        }
        activeSheet = .extractJPGs
    }

    func startSelectedJPGExtraction(destination: ARWSourceCatalog, exportMode: ExtractJPGExportMode) {
        let exportFiles = selectedFilesForJPGExtraction
        guard currentScanAndExtractJPGsActor == nil,
              currentScanAndCreateThumbnailsActor == nil,
              currentExtractAndSaveJPGsActor == nil,
              !exportFiles.isEmpty
        else { return }

        progress = 0
        max = Double(exportFiles.count)
        estimatedSeconds = 0
        creatingthumbnails = true

        let handlers = CreateFileHandlers().createFileHandlers(
            fileHandler: fileHandler,
            maxfilesHandler: maxfilesHandler,
            estimatedTimeHandler: estimatedTimeHandler,
            memorypressurewarning: { _ in },
            onExtractionNeeded: {},
        )

        let destinationURL = destination.url
        let destinationAccessStarted = startSecurityScopedResource(destinationURL)
        let extract = ExtractAndSaveJPGs(
            files: exportFiles,
            destinationCatalogURL: destinationURL,
            exportMode: exportMode,
        )
        currentExtractAndSaveJPGsActor = extract

        Task(priority: .background) {
            await extract.setFileHandlers(handlers)
            await extract.extractAndSavejpgs()

            await MainActor.run {
                if destinationAccessStarted {
                    self.stopSecurityScopedResource(destinationURL)
                }
                guard self.currentExtractAndSaveJPGsActor === extract else { return }
                self.currentExtractAndSaveJPGsActor = nil
                self.creatingthumbnails = false
            }
        }
    }

    func startScanAndExtractJPGs() {
        guard currentScanAndExtractJPGsActor == nil,
              currentScanAndCreateThumbnailsActor == nil,
              currentExtractAndSaveJPGsActor == nil,
              !files.isEmpty
        else { return }

        jpgCacheWarmTask?.cancel()

        progress = 0
        max = Double(files.count)
        estimatedSeconds = 0
        creatingthumbnails = true

        let handlers = CreateFileHandlers().createFileHandlers(
            fileHandler: fileHandler,
            maxfilesHandler: maxfilesHandler,
            estimatedTimeHandler: estimatedTimeHandler,
            memorypressurewarning: { _ in },
            onExtractionNeeded: {},
        )

        let actor = ScanAndExtractJPGs(urls: files.map(\.url))
        currentScanAndExtractJPGsActor = actor

        jpgCacheWarmTask = Task(priority: .background) {
            await actor.setFileHandlers(handlers)
            await actor.extractCatalogJPGs()

            await MainActor.run {
                guard self.currentScanAndExtractJPGsActor === actor else { return }
                self.currentScanAndExtractJPGsActor = nil
                self.jpgCacheWarmTask = nil
                self.creatingthumbnails = false
            }
        }
    }

    func startSAM3MaskCreationForFilteredCatalog() {
        startSAM3MaskCreationHelperForCatalog()
    }

    func startSAM3MaskCreationHelperForCatalog() {
        let targetFiles = sam3MaskCreationTargetFiles
        guard !isCreatingSAM3Masks,
              let catalogURL = selectedSource?.url,
              !targetFiles.isEmpty
        else { return }

        guard sam3ModelResourceManager.installedModelURL() != nil else {
            sam3MaskCreationTask?.cancel()
            sam3MaskCreationProgress = SubjectMaskPrefetchProgress(
                completed: 0,
                total: targetFiles.count,
                cached: 0,
                generated: 0,
                failed: 0,
                currentFileID: targetFiles.first?.id,
            )
            sam3MaskCreationStatusText = "Could not start SAM3 mask helper: SAM3 model resources are missing. Open Settings > AI to install them."
            isCreatingSAM3Masks = true
            return
        }

        sam3MaskCreationTask?.cancel()
        sam3MaskCreationProgress = SubjectMaskPrefetchProgress(
            completed: 0,
            total: targetFiles.count,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileID: targetFiles.first?.id,
        )
        sam3MaskCreationStatusText = "Starting SAM3 mask helper..."
        isCreatingSAM3Masks = true

        do {
            try sam3MaskHelperController.start(
                catalogURL: catalogURL,
                targetFiles: targetFiles,
                onEvent: { [weak self] event in
                    self?.handleSAM3MaskHelperEvent(event)
                },
                onExit: { [weak self] exitCode, errorOutput in
                    self?.handleSAM3MaskHelperExit(exitCode, errorOutput: errorOutput)
                },
            )
        } catch {
            sam3MaskCreationStatusText = "Could not start SAM3 mask helper: \(error.localizedDescription)"
            isCreatingSAM3Masks = true
        }
    }

    func startSAM3MaskCreationForFilteredCatalog(
        actor: SubjectSegmentationActor,
        imageLoader: @escaping @Sendable (FileItem) async -> CGImage?,
    ) {
        guard !isCreatingSAM3Masks else { return }
        let files = sam3MaskCreationCandidateFiles
        guard !files.isEmpty else { return }

        sam3MaskCreationTask?.cancel()
        sam3MaskCreationProgress = SubjectMaskPrefetchProgress(
            completed: 0,
            total: files.count,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileID: files.first?.id,
        )
        isCreatingSAM3Masks = true

        sam3MaskCreationTask = Task(priority: .background) {
            do {
                let pipeline = SAM3MaskGenerationPipeline(
                    actor: actor,
                    imageLoader: imageLoader,
                )
                _ = try await pipeline.generate(
                    files: files,
                    progress: { event in
                        await MainActor.run {
                            self.sam3MaskCreationProgress = event.prefetchProgress
                        }
                    },
                )
            } catch {}

            await MainActor.run {
                self.sam3MaskCreationTask = nil
                self.isCreatingSAM3Masks = false
            }
        }
    }

    func cancelSAM3MaskCreation(clearProgress: Bool = false) {
        sam3MaskCreationTask?.cancel()
        sam3MaskCreationTask = nil
        sam3MaskHelperController.cancel()
        isCreatingSAM3Masks = false
        sam3MaskCreationStatusText = ""
        if clearProgress {
            sam3MaskCreationProgress = nil
        }
    }

    private func handleSAM3MaskHelperEvent(_ event: SAM3MaskBuildEvent) {
        switch event.kind {
        case .started:
            sam3MaskCreationProgress = event.prefetchProgress
            sam3MaskCreationStatusText = "Creating SAM3 masks..."

        case .progress:
            sam3MaskCreationProgress = event.prefetchProgress
            if let currentFileName = event.currentFileName {
                sam3MaskCreationStatusText = "Creating SAM3 mask: \(currentFileName)"
            } else {
                sam3MaskCreationStatusText = "Creating SAM3 masks..."
            }

        case .completed:
            sam3MaskCreationProgress = event.prefetchProgress
            sam3MaskCreationStatusText = "Completed: restarting RawCull"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSApplication.shared.terminate(nil)
            }

        case .failed:
            sam3MaskCreationStatusText = event.message ?? "SAM3 mask helper failed."
            isCreatingSAM3Masks = true
        }
    }

    private func handleSAM3MaskHelperExit(_ exitCode: Int32, errorOutput: String?) {
        guard isCreatingSAM3Masks else { return }
        if sam3MaskCreationStatusText == "Completed: restarting RawCull" {
            return
        }
        if exitCode != 0 {
            if let errorOutput, !errorOutput.isEmpty {
                sam3MaskCreationStatusText = "SAM3 mask helper exited with code \(exitCode): \(errorOutput)"
            } else {
                sam3MaskCreationStatusText = "SAM3 mask helper exited with code \(exitCode)."
            }
            isCreatingSAM3Masks = true
        } else {
            isCreatingSAM3Masks = false
        }
    }

    func applyStoredScoringSettings() async {
        // Wait for the initial settings load to complete before reading.
        // Without this, we may race with the fire-and-forget Task in SettingsViewModel.init()
        // and read default values from the JSON before the file I/O finishes.
        await SettingsViewModel.shared.ensureLoaded()
        let s = SettingsViewModel.shared
        sharpnessModel.thumbnailMaxPixelSize = SharpnessScoringSizeOption.normalizedPixelSize(
            s.scoringThumbnailMaxPixelSize,
            for: s.scoringQuality,
        )
        sharpnessModel.focusMaskModel.config.borderInsetFraction = s.scoringBorderInsetFraction
        sharpnessModel.focusMaskModel.config.enableSubjectClassification = s.scoringEnableSubjectClassification
        sharpnessModel.focusMaskModel.config.salientWeight = s.scoringSalientWeight
        sharpnessModel.focusMaskModel.config.subjectSizeFactor = s.scoringSubjectSizeFactor
        sharpnessModel.focusMaskModel.config.preBlurRadius = s.focusMaskPreBlurRadius
        sharpnessModel.photoType = s.scoringPhotoType
        sharpnessModel.scoringQuality = s.scoringQuality
        sharpnessModel.scoringSource = s.scoringSource
        sharpnessModel.focusMaskModel.config.threshold = s.focusMaskThreshold
        sharpnessModel.focusMaskModel.config.energyMultiplier = s.focusMaskEnergyMultiplier
        sharpnessModel.focusMaskModel.config.erosionRadius = s.focusMaskErosionRadius
        sharpnessModel.focusMaskModel.config.dilationRadius = s.focusMaskDilationRadius
        sharpnessModel.focusMaskModel.config.featherRadius = s.focusMaskFeatherRadius
    }

    func abort() {
        Logger.process.debugMessageOnly("Abort scanning")

        cancelCatalogLoad()

        if let actor = currentExtractAndSaveJPGsActor {
            Task { await actor.cancelExtractJPGSTask() }
        }
        currentExtractAndSaveJPGsActor = nil

        jpgCacheWarmTask?.cancel()
        jpgCacheWarmTask = nil

        if let actor = currentScanAndExtractJPGsActor {
            Task { await actor.cancelExtraction() }
        }
        currentScanAndExtractJPGsActor = nil

        cancelSAM3MaskCreation(clearProgress: true)

        creatingthumbnails = false
    }
}
