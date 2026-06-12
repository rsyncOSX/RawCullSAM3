//
//  RawCullViewModel+Thumbnails.swift
//  RawCull
//

import CoreGraphics
import OSLog

extension RawCullViewModel {
    var sam3MaskCreationCandidateFiles: [FileItem] {
        let candidates = filteredFiles.filter { passesRatingFilter($0) }
        guard !sharpnessModel.sortBySharpness else { return candidates }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    func requestCreateSAM3MasksConfirmation() {
        guard !isCreatingSAM3Masks,
              !sam3MaskCreationCandidateFiles.isEmpty
        else { return }
        alertType = .createSAM3Masks
        showingAlert = true
    }

    func startSAM3MaskCreationForFilteredCatalog() {
        startSAM3MaskCreationForFilteredCatalog(
            actor: sam3SubjectSegmentationActor,
            imageLoader: { file in
                await ZoomPreviewHandler.loadExtractedJPGPreview(for: file.url)
            },
        )
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
                try await actor.prefetch(
                    files: files,
                    prompt: SAM3SubjectMaskCacheReader.prompt,
                    imageLoader: imageLoader,
                    progress: { progress in
                        await MainActor.run {
                            self.sam3MaskCreationProgress = progress
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
        isCreatingSAM3Masks = false
        if clearProgress {
            sam3MaskCreationProgress = nil
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
