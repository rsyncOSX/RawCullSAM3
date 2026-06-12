import SwiftUI

nonisolated enum LoupeImageKeyAction: Equatable {
    case zoomIn
    case zoomOut
    case toggleEmbeddedJPG
    case toggleDevelopedRAW

    nonisolated static func resolve(characters: String?) -> LoupeImageKeyAction? {
        switch characters {
        case "+":
            .zoomIn

        case "-":
            .zoomOut

        case "j", "J":
            .toggleEmbeddedJPG

        case "r", "R":
            .toggleDevelopedRAW

        default:
            nil
        }
    }
}

struct MainThumbnailImageView: View {
    @Environment(RawCullViewModel.self) private var viewModel

    private var focusPoints: [FocusPoint]? {
        viewModel.getFocusPoints()
    }

    let url: URL
    let file: FileItem?

    @State private var image: NSImage?
    @State private var thumbnailSizePreview: Int?
    @State private var sourceSelection = ImageSourceSelectionState()
    @State private var embeddedJPGImage: CGImage?
    @State private var developedRAWImage: CGImage?
    @State private var isLoadingSource = false
    @State private var sourceTask: Task<Void, Never>?
    @State private var showRAWNotSupported = false
    @State private var rawMessageTask: Task<Void, Never>?

    @State private var showFocusPoints = false
    @State private var subjectMask: CGImage?
    @State private var showSubjectMask = false
    @State private var subjectSegmentationState: SubjectSegmentationControlState = .idle
    @State private var subjectSegmentationActor = SubjectSegmentationActor()
    @State private var subjectPrefetchTask: Task<Void, Never>?
    @State private var subjectPrefetchProgress: SubjectMaskPrefetchProgress?
    @State private var subjectMaskLoadTask: Task<Void, Never>?

    // Focus mask state
    @State private var focusMask: NSImage?
    @State private var showFocusMask: Bool = false
    @State private var isGeneratingFocusMask = false
    @State private var focusMaskSourceURL: URL?
    @State private var maskTask: Task<Void, Never>?
    @FocusState private var isImageFocused: Bool

    var body: some View {
        ZStack {
            if let thumbnailSizePreview {
                VStack {
                    GeometryReader { geo in
                        ZStack {
                            // 1️⃣ Image FIRST (background)
                            displayedImageContent(thumbnailSizePreview: thumbnailSizePreview)
                                .scaleEffect(viewModel.scale)
                                .offset(viewModel.offset)
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                                .gesture(
                                    MagnifyGesture()
                                        .onChanged { value in
                                            viewModel.scale = viewModel.lastScale * value.magnification
                                        }
                                        .onEnded { _ in
                                            viewModel.lastScale = viewModel.scale
                                        },
                                )

                                .simultaneousGesture(
                                    DragGesture()
                                        .onChanged { value in
                                            if viewModel.scale > 1.0 {
                                                viewModel.offset = CGSize(
                                                    width: viewModel.lastOffset.width + value.translation.width,
                                                    height: viewModel.lastOffset.height + value.translation.height,
                                                )
                                            }
                                        }
                                        .onEnded { _ in
                                            viewModel.lastOffset = viewModel.offset
                                        },
                                )

                            // 2️⃣ Focus mask overlay

                            if showFocusMask, let mask = focusMask {
                                Image(nsImage: mask)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .scaleEffect(viewModel.scale)
                                    .offset(viewModel.offset)
                                    .blendMode(.screen)
                                    .opacity(0.95)
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }

                            if showSubjectMask, let subjectMask {
                                Image(decorative: subjectMask, scale: 1.0, orientation: .up)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .scaleEffect(viewModel.scale)
                                    .offset(viewModel.offset)
                                    .blendMode(.plusLighter)
                                    .opacity(0.72)
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }

                            // 3️⃣ Focus points overlay
                            if showFocusPoints, let focusPoints {
                                FocusOverlayView(
                                    focusPoints: focusPoints,
                                    imageSize: currentImageSize,
                                )
                                .scaleEffect(viewModel.scale)
                                .offset(viewModel.offset)
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .blurReplace))
                            }

                            VStack {
                                // File metadata at the top where it belongs
                                if let file {
                                    HStack(alignment: .top, spacing: 8) {
                                        SubjectMaskScanButton(
                                            isRunning: subjectPrefetchTask != nil,
                                            progress: subjectPrefetchProgress,
                                            density: .compact,
                                            onStart: startSubjectMaskScan,
                                            onCancel: { cancelSubjectMaskScan(clearProgress: false) },
                                        )

                                        CurrentRatingBadgeView(
                                            rating: ratingDisplay(for: file),
                                            density: .compact,
                                        )

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name)
                                                .font(.headline)
                                            Text(file.url.deletingLastPathComponent().path())
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.regularMaterial)
                                    .clipShape(.rect(cornerRadius: 8))
                                    .padding([.top, .horizontal], 8)
                                }

                                Spacer()

                                ImageOverlayControlsView(
                                    showFocusMask: $showFocusMask,
                                    focusMaskAvailable: currentDisplayedImage != nil,
                                    showSubjectSegmentation: subjectMask != nil,
                                    showSubjectMask: $showSubjectMask,
                                    subjectMaskEnabled: subjectMask != nil,
                                    subjectMaskAvailable: subjectMask != nil,
                                    subjectSegmentationState: subjectSegmentationState,
                                    onToggleSubjectMask: toggleSubjectMask,
                                    hasFocusPoints: focusPoints != nil,
                                    showFocusPoints: $showFocusPoints,
                                    showShortcutHints: true,
                                    showImageSourceToggle: true,
                                    useThumbnailSource: useThumbnailSourceBinding,
                                    imageSourceSelection: $sourceSelection,
                                    scale: viewModel.scale,
                                    canZoomOut: viewModel.scale > 0.5,
                                    canZoomIn: viewModel.scale < 4.0,
                                    canReset: viewModel.scale != 1.0 || viewModel.offset != .zero,
                                    onZoomOut: { withAnimation(.spring()) { viewModel.scale = max(0.5, viewModel.scale - 0.2) } },
                                    onZoomReset: { withAnimation(.spring()) { viewModel.resetZoom() } },
                                    onZoomIn: { withAnimation(.spring()) { viewModel.scale = min(4.0, viewModel.scale + 0.2) } },
                                )
                                .padding(.bottom, 12)
                            }

                            if showRAWNotSupported {
                                Text("Not supported")
                                    .font(.title2.weight(.semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(.regularMaterial, in: Capsule())
                                    .transition(.opacity)
                            }
                        }
                        .focusable()
                        .focused($isImageFocused)
                        .focusEffectDisabled(true)
                        .onKeyPress(characters: CharacterSet(charactersIn: "+-jJrR")) { press in
                            handleKeyAction(LoupeImageKeyAction.resolve(characters: press.characters))
                        }
                        .onAppear { isImageFocused = true }
                    }
                }
                .shadow(radius: 4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 8))
            } else {
                ProgressView()
                    .fixedSize()
            }
        }
        .task {
            let settingsmanager = await SettingsViewModel.shared.asyncgetsettings()
            thumbnailSizePreview = settingsmanager.thumbnailSizePreview
            reloadCachedSubjectMask()
        }
        .onChange(of: showFocusMask) { _, newValue in
            if newValue {
                generateFocusMaskIfNeeded()
            } else if isGeneratingFocusMask {
                maskTask?.cancel()
                maskTask = nil
                isGeneratingFocusMask = false
            }
        }
        .onChange(of: sourceSelection.selected) { _, _ in
            resetFocusMaskImage()
            reloadCachedSubjectMask()
            loadSelectedSourceIfNeeded()
        }
        .onChange(of: viewModel.sharpnessModel.focusMaskModel.config) { _, _ in
            maskTask?.cancel()
            focusMask = nil
            focusMaskSourceURL = nil
            guard showFocusMask else {
                isGeneratingFocusMask = false
                maskTask = nil
                return
            }
            maskTask = Task {
                isGeneratingFocusMask = true
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await regenerateMask()
                isGeneratingFocusMask = false
            }
        }
        .onChange(of: url) { _, _ in
            resetSourceImages()
            sourceSelection.resetForNewImage()
            clearRAWMessage()
            resetFocusMaskState()
            resetSubjectMaskState()
            loadSelectedSourceIfNeeded()
            reloadCachedSubjectMask()
        }
        .onDisappear {
            maskTask?.cancel()
            maskTask = nil
            isGeneratingFocusMask = false
            sourceTask?.cancel()
            sourceTask = nil
            rawMessageTask?.cancel()
            rawMessageTask = nil
            subjectMaskLoadTask?.cancel()
            subjectMaskLoadTask = nil
            cancelSubjectMaskScan(clearProgress: true)
            subjectMask = nil
            showSubjectMask = false
            isLoadingSource = false
        }
    }

    @ViewBuilder
    private func displayedImageContent(thumbnailSizePreview: Int) -> some View {
        switch sourceSelection.selected {
        case .thumbnail:
            ThumbnailImageView(
                url: url,
                targetSize: thumbnailSizePreview,
                style: .list,
                showsShimmer: false,
                contentMode: .fit,
                image: $image,
            )

        case .embeddedJPG:
            if let embeddedJPGImage {
                Image(decorative: embeddedJPGImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else if isLoadingSource {
                ProgressView()
                    .fixedSize()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                    Text("No extracted JPG")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

        case .developedRAW:
            if let developedRAWImage {
                Image(decorative: developedRAWImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .fixedSize()
            }
        }
    }

    private var currentDisplayedImage: NSImage? {
        if sourceSelection.selected == .embeddedJPG, let embeddedJPGImage {
            return NSImage(
                cgImage: embeddedJPGImage,
                size: NSSize(width: embeddedJPGImage.width, height: embeddedJPGImage.height),
            )
        }
        if sourceSelection.selected == .developedRAW, let developedRAWImage {
            return NSImage(cgImage: developedRAWImage, size: .zero)
        }
        return image
    }

    private var currentImageSize: NSSize? {
        if sourceSelection.selected == .embeddedJPG, let embeddedJPGImage {
            return NSSize(width: embeddedJPGImage.width, height: embeddedJPGImage.height)
        }
        if sourceSelection.selected == .developedRAW, let developedRAWImage {
            return NSSize(width: developedRAWImage.width, height: developedRAWImage.height)
        }
        return image?.size
    }

    private var useThumbnailSourceBinding: Binding<Bool> {
        Binding(
            get: { sourceSelection.selected == .thumbnail },
            set: { sourceSelection.select($0 ? .thumbnail : .embeddedJPG) },
        )
    }

    private func handleKeyAction(_ action: LoupeImageKeyAction?) -> KeyPress.Result {
        guard let action else { return .ignored }
        switch action {
        case .zoomIn:
            withAnimation(.spring()) {
                viewModel.scale = min(4.0, viewModel.scale + 0.2)
                viewModel.lastScale = viewModel.scale
            }
            return .handled

        case .zoomOut:
            withAnimation(.spring()) {
                viewModel.scale = max(0.5, viewModel.scale - 0.2)
                viewModel.lastScale = viewModel.scale
            }
            return .handled

        case .toggleEmbeddedJPG:
            sourceSelection.toggleExtractionSource(.embeddedJPG)
            return .handled

        case .toggleDevelopedRAW:
            sourceSelection.toggleExtractionSource(.developedRAW)
            return .handled
        }
    }

    private func loadSelectedSourceIfNeeded() {
        sourceTask?.cancel()
        sourceTask = nil

        let requestedSource = sourceSelection.selected
        guard requestedSource != .thumbnail else {
            isLoadingSource = false
            if showFocusMask { generateFocusMaskIfNeeded() }
            return
        }
        if requestedSource == .embeddedJPG, embeddedJPGImage != nil { return }
        if requestedSource == .developedRAW, developedRAWImage != nil { return }

        isLoadingSource = true
        sourceTask = Task {
            do {
                let loadedImage: CGImage? = switch requestedSource {
                case .thumbnail:
                    nil

                case .embeddedJPG:
                    await ZoomPreviewHandler.loadExtractedJPGPreview(for: url)

                case .developedRAW:
                    try await ZoomPreviewHandler.loadDevelopedRAWPreview(for: url)
                }
                guard !Task.isCancelled, sourceSelection.selected == requestedSource else { return }
                if requestedSource == .embeddedJPG {
                    embeddedJPGImage = loadedImage
                } else {
                    developedRAWImage = loadedImage
                }
                isLoadingSource = false
                if showFocusMask { generateFocusMaskIfNeeded() }
                reloadCachedSubjectMask()
            } catch is CancellationError {
                return
            } catch {
                guard sourceSelection.selected == .developedRAW else { return }
                isLoadingSource = false
                sourceSelection.markDevelopedRAWUnavailable()
                showRAWFailureMessage()
            }
        }
    }

    private func ratingDisplay(for file: FileItem) -> RatingDisplay {
        RatingDisplay(
            rating: viewModel.getRating(for: file),
            isExplicit: viewModel.taggedNamesCache.contains(file.name),
        )
    }

    // MARK: - Subject Mask

    private var subjectScanFiles: [FileItem] {
        let filtered = viewModel.filteredFiles.filter { viewModel.passesRatingFilter($0) }
        if !filtered.isEmpty {
            return viewModel.sharpnessModel.sortBySharpness
                ? filtered
                : filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let file {
            return [file]
        }
        return []
    }

    private func toggleSubjectMask() {
        guard subjectMask != nil else {
            showSubjectMask = false
            return
        }
        showSubjectMask.toggle()
    }

    private func reloadCachedSubjectMask() {
        subjectMaskLoadTask?.cancel()
        subjectMaskLoadTask = nil
        subjectMask = nil
        subjectSegmentationState = .idle
        showSubjectMask = false

        guard let file else { return }
        subjectMaskLoadTask = Task {
            let result = await SAM3SubjectMaskCacheReader.loadCachedMask(for: file)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.file?.id == file.id else { return }
                subjectMask = result?.mask
                subjectSegmentationState = result.map { .ready($0.diagnostics) } ?? .idle
            }
        }
    }

    private func startSubjectMaskScan() {
        let files = subjectScanFiles
        guard !files.isEmpty else { return }

        subjectPrefetchTask?.cancel()
        subjectPrefetchProgress = SubjectMaskPrefetchProgress(
            completed: 0,
            total: files.count,
            cached: 0,
            generated: 0,
            failed: 0,
            currentFileID: files.first?.id,
        )

        let actor = subjectSegmentationActor
        subjectPrefetchTask = Task {
            do {
                try await actor.prefetch(
                    files: files,
                    prompt: SAM3SubjectMaskCacheReader.prompt,
                    imageLoader: { file in
                        await ZoomPreviewHandler.loadExtractedJPGPreview(for: file.url)
                    },
                    progress: { progress in
                        await MainActor.run {
                            subjectPrefetchProgress = progress
                        }
                    },
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    subjectPrefetchTask = nil
                    reloadCachedSubjectMask()
                }
            } catch {
                await MainActor.run {
                    subjectPrefetchTask = nil
                }
            }
        }
    }

    private func cancelSubjectMaskScan(clearProgress: Bool) {
        subjectPrefetchTask?.cancel()
        subjectPrefetchTask = nil
        if clearProgress {
            subjectPrefetchProgress = nil
        }
    }

    private func resetSubjectMaskState() {
        subjectMaskLoadTask?.cancel()
        subjectMaskLoadTask = nil
        subjectMask = nil
        showSubjectMask = false
        subjectSegmentationState = .idle
        cancelSubjectMaskScan(clearProgress: true)
    }

    // MARK: - Regenerate Mask

    private func generateFocusMaskIfNeeded() {
        guard focusMaskSourceURL != url || focusMask == nil else { return }
        guard currentDisplayedImage != nil, !isGeneratingFocusMask else { return }

        maskTask?.cancel()
        maskTask = Task {
            isGeneratingFocusMask = true
            await regenerateMask()
            isGeneratingFocusMask = false
        }
    }

    private func regenerateMask() async {
        guard let image = currentDisplayedImage else { return }
        let config = focusMaskConfig()
        let mask = await viewModel.sharpnessModel.focusMaskModel.generateFocusMask(
            from: image,
            scale: 1.0,
            configOverride: config,
            afPoint: file?.afFocusNormalized,
            evidence: file.flatMap { viewModel.sharpnessModel.breakdowns[$0.id]?.focusEvidence },
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.focusMask = mask
            self.focusMaskSourceURL = url
        }
    }

    private func focusMaskConfig() -> FocusDetectorConfig {
        guard let file else { return viewModel.sharpnessModel.effectiveFocusConfig }
        var config = viewModel.sharpnessModel.effectiveFocusConfig
        config.iso = file.exifData?.isoValue ?? 400
        config.apertureHint = FocusDetectorConfig.ApertureHint.from(aperture: file.exifData?.apertureValue)
        if let score = viewModel.sharpnessModel.scores[file.id],
           SharpnessLabel(score: score, maxScore: viewModel.sharpnessModel.maxScore) == .sharp {
            config.guaranteeVisibleFocusEvidence = true
        }
        return config
    }

    private func resetFocusMaskState() {
        maskTask?.cancel()
        maskTask = nil
        focusMask = nil
        focusMaskSourceURL = nil
        showFocusMask = false
        isGeneratingFocusMask = false
    }

    private func resetFocusMaskImage() {
        maskTask?.cancel()
        maskTask = nil
        focusMask = nil
        focusMaskSourceURL = nil
        isGeneratingFocusMask = false
    }

    private func resetSourceImages() {
        sourceTask?.cancel()
        sourceTask = nil
        embeddedJPGImage = nil
        developedRAWImage = nil
        isLoadingSource = false
    }

    private func showRAWFailureMessage() {
        rawMessageTask?.cancel()
        withAnimation { showRAWNotSupported = true }
        rawMessageTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation { showRAWNotSupported = false }
        }
    }

    private func clearRAWMessage() {
        rawMessageTask?.cancel()
        rawMessageTask = nil
        showRAWNotSupported = false
    }
}
